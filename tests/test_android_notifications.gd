extends SimTest
## The notification **platform** (doc 13 §2.4/§2.5/§2.6/§2.7 + doc 01 §2.11).
##
## Doc 08's policy half — classes, buckets, quiet hours, coalescing — is
## `tests/test_notifications.gd` and is not re-tested here. What this file holds
## is the half that only exists because the game runs on a phone that will not
## run it:
##
##   * **the conversion**, tick → wall-clock millisecond, which doc 01 §2.11 owns
##     and which is the difference between "your building is done" arriving when
##     the building is done and arriving at a moment the sim never reaches;
##   * **the two guards**, the 12-real-hour offline cap and the Doze slop floor,
##     both of which DROP notifications on purpose;
##   * **the ETA walk**, which derives a completion tick that is stored nowhere,
##     and is asserted against `ConstructionQueue.advance()` actually running;
##   * **the budget rewind**, so that spending tokens on a future that gets
##     cancelled does not cost the player anything;
##   * **the permission state machine**, whose entire job is to not ask;
##   * **the seam**, which must still degrade to a no-op with no plugin, because
##     that is what desktop, the headless runner and this test run are.
##
## The Kotlin cannot run here, so `FakeNative` stands in for the plugin and
## records what the platform was asked to do. Every assertion below is about the
## GDScript decision, never about Android — the parts that need a device are doc
## 13 §7's D-01…D-16 and they are on-device by construction.

const TICKS_PER_MINUTE := 4
const REAL_MS_PER_TICK := 250
## doc 01 `catchup.offline_cap_real_ms` / 1000 — 12 real hours (ruling C-19).
const OFFLINE_CAP_S := 43_200.0
## An arbitrary but fixed unix second; every fire time below is relative to it.
const NOW_UNIX := 1_800_000_000.0


## A `SlacumNative` that implements the notification surface and remembers what
## it was told. Subclassing rather than mocking: the production bridge's
## `has_method` probes and its null guards stay in the path.
class FakeNative extends AndroidNative:
	var available := true
	var supports := true
	var enabled := true
	var permission := AndroidNative.PERMISSION_GRANTED
	var channels: Array[Dictionary] = []
	var posted: Array[Dictionary] = []
	var cancels := 0
	var requests := 0
	var settings_opened := 0

	func is_available() -> bool:
		return available

	func supports_notifications() -> bool:
		return available and supports

	func notifications_enabled() -> bool:
		return available and enabled

	func permission_state() -> String:
		return permission if available else AndroidNative.PERMISSION_UNSUPPORTED

	func request_notification_permission() -> bool:
		if not available:
			return false
		requests += 1
		return true

	func open_app_notification_settings() -> bool:
		settings_opened += 1
		return available

	func ensure_channel(channel_id: String, name: String, importance: String,
			sound: bool, vibrate: bool) -> bool:
		if not supports_notifications():
			return false
		channels.append({"id": channel_id, "name": name, "importance": importance,
				"sound": sound, "vibrate": vibrate})
		return true

	func post_notification(plan: Dictionary) -> bool:
		if not supports_notifications():
			return false
		posted.append(plan.duplicate(true))
		return true

	func cancel_notifications() -> int:
		cancels += 1
		var count := posted.size()
		posted.clear()
		return count


## The read surface `NotificationScheduler` uses, and nothing else — the point of
## duck-typing that surface is that a test can supply exactly the four members
## without booting a city.
class StubSim extends RefCounted:
	var clock: GameClock
	var curves: DayCurveSet
	var modifiers: ModifierStack
	var construction: ConstructionQueue
	var timers: TimerService
	var director: StubDirector
	var buildings: Dictionary = {}

	func _init() -> void:
		clock = GameClock.new()
		curves = DayCurveSet.new()
		modifiers = ModifierStack.new()
		construction = ConstructionQueue.new()
		timers = TimerService.new()
		director = StubDirector.new()
		var time_data: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("res://data/time.json"))
		if time_data is Dictionary:
			curves.load_from(time_data)


class StubDirector extends RefCounted:
	var rows: Array = []

	func forecast_queue() -> Array:
		return rows


func _cfg() -> NotificationConfig:
	return NotificationConfig.load_from_files()


func _scheduler() -> NotificationScheduler:
	var scheduler := NotificationScheduler.load_from_files()
	scheduler.configure(_cfg().delivery())
	return scheduler


## A router on a fixed clock, with the platform faked underneath it.
func _router(native: FakeNative) -> NotificationRouter:
	var sink := NativeNotificationSink.new(native, NotificationText.load_from_files())
	var router := NotificationRouter.new(_cfg(), null)
	router.wall_clock = func() -> float: return NOW_UNIX / 60.0
	router.local_minute_of_day = func() -> int: return 9 * 60
	# A fixed zero offset, so a fire time's local hour is arithmetic rather than
	# a property of the machine the suite happens to run on.
	router.utc_offset_minutes = func() -> int: return 0
	router.scheduler = _scheduler()
	router.set_sink(sink)
	return router


# ===========================================================================
# doc 01 §2.11 — the conversion, and the two guards
# ===========================================================================

func test_01_tick_to_wall_conversion_is_doc_01s_worked_example() -> void:
	# doc 01 §2.11: "Construction completing at tick 919 700, backgrounded at
	# tick 918 442 → (919 700 − 918 442) × 250 = 314 500 ms." That is 5 min 14 s
	# of real time for a 5-game-hour job, which is what 60× means in practice.
	var scheduler := _scheduler()
	var sim := StubSim.new()
	sim.clock.tick_index = 918_442
	sim.timers.schedule(&"notification", &"test", 919_700,
			{"notify_id": "construction_complete", "ref": "B-1", "args": {"level": 2}}, true)
	scheduler.doze_guard_enabled = false  # 314 s is inside the Doze floor by design
	var entries := scheduler.collect(sim, NOW_UNIX)
	assert_eq(entries.size(), 1, "one flagged timer, one entry")
	assert_almost_eq(float(entries[0]["real_delay_s"]), 314.5, 0.001,
			"1 258 ticks × 250 ms = 314 500 ms")
	assert_almost_eq(float(entries[0]["fire_at_unix"]), NOW_UNIX + 314.5, 0.001)


func test_02_the_offline_cap_drops_what_the_catchup_will_never_reach() -> void:
	# doc 13 §2.4's worked pair: a timer 42 000 real seconds out is scheduled; one
	# 44 000 out is dropped, because `elapsed` clamps at 43 200 and the sim would
	# still be short of that tick when the player returns. An alarm for an event
	# that has not happened is worse than silence.
	var scheduler := _scheduler()
	var sim := StubSim.new()
	sim.clock.tick_index = 0
	var inside := int(42_000.0 * 1000.0 / REAL_MS_PER_TICK)
	var outside := int(44_000.0 * 1000.0 / REAL_MS_PER_TICK)
	sim.timers.schedule(&"notification", &"test", inside,
			{"notify_id": "construction_complete", "ref": "IN"}, true)
	sim.timers.schedule(&"notification", &"test", outside,
			{"notify_id": "construction_complete", "ref": "OUT"}, true)
	var entries := scheduler.collect(sim, NOW_UNIX)
	assert_eq(entries.size(), 1, "one of the two is beyond the cap")
	assert_eq(str(entries[0]["ref"]), "IN")
	assert_almost_eq(scheduler.offline_cap_s, OFFLINE_CAP_S, 0.001,
			"the cap is read from data/time.json, not defined here")
	assert_eq(str(scheduler.last_drops[0]["reason"]), "beyond_offline_cap")


func test_03_the_doze_guard_drops_what_would_arrive_too_late() -> void:
	# doc 13 §2.5 / test A-08. Alarms are inexact BY CHOICE, so anything with less
	# than doze_slop_s + min_useful_lead_s = 1 200 s of lead can land after the
	# thing it warns about. 900 s → dropped. 1 260 s → accepted.
	var scheduler := _scheduler()
	assert_almost_eq(scheduler.doze_slop_s, 900.0, 0.001)
	assert_almost_eq(scheduler.min_useful_lead_s, 300.0, 0.001)
	for pair: Array in [[900.0, 0], [1_260.0, 1]]:
		var sim := StubSim.new()
		sim.clock.tick_index = 0
		var due := int(float(pair[0]) * 1000.0 / REAL_MS_PER_TICK)
		sim.timers.schedule(&"notification", &"test", due,
				{"notify_id": "weather_warning", "ref": "W"}, true)
		var entries := scheduler.collect(sim, NOW_UNIX)
		assert_eq(entries.size(), int(pair[1]),
				"lead %.0f s → %d scheduled" % [float(pair[0]), int(pair[1])])


func test_04_a_timer_without_a_notify_id_is_not_a_message() -> void:
	var scheduler := _scheduler()
	var sim := StubSim.new()
	sim.clock.tick_index = 0
	sim.timers.schedule(&"hazard_phase", &"director", 20_000, {}, true)
	sim.timers.schedule(&"policy_window", &"econ", 20_000, {}, false)
	assert_eq(scheduler.collect(sim, NOW_UNIX).size(), 0,
			"a flagged timer with nothing to render schedules nothing")


func test_05_only_events_the_delivery_map_names_can_be_pre_scheduled() -> void:
	# `delivery.offline_sources` is doc 13's half of data/notifications.json: it
	# says which events are predictable at pause time at all. An emergent one —
	# a blackout, a fire — needs a projection, and projection ships DISABLED.
	var scheduler := _scheduler()
	assert_true(scheduler.offline_allowed("construction_complete"))
	assert_true(scheduler.offline_allowed("weather_warning"))
	assert_false(scheduler.offline_allowed("outage_major"),
			"a blackout cannot be predicted from the save")
	var sim := StubSim.new()
	sim.clock.tick_index = 0
	sim.timers.schedule(&"notification", &"test", 20_000,
			{"notify_id": "outage_major", "ref": "X"}, true)
	assert_eq(scheduler.collect(sim, NOW_UNIX).size(), 0)
	assert_eq(str(scheduler.last_drops[0]["reason"]), "not_offline_schedulable")


# ===========================================================================
# The ETA walk — a completion time that is stored nowhere
# ===========================================================================

func test_06_construction_eta_matches_the_queue_actually_running() -> void:
	# A job carries work units, not a deadline, and `construction_rate` is a day
	# curve — so the completion tick has to be DERIVED by walking the curve. The
	# only honest test of that derivation is to run the real queue and see where
	# it lands: predict first, then advance an hour at a time until the job
	# completes, and require the prediction to name that hour.
	var sim := StubSim.new()
	sim.clock.tick_index = GameClock.TICKS_PER_HOUR * 9  # 15:00 on founding day
	var job_id := sim.construction.submit(&"build", "B-7", 8.0, &"construction_crew",
			{"sim_id": "B-7"})
	sim.construction.assign_crew(job_id, "YARD-CREW-1")
	var job := sim.construction.job(job_id)

	var scheduler := _scheduler()
	var predicted := scheduler.eta_tick(sim, job, sim.clock.tick_index)
	assert_true(predicted > sim.clock.tick_index, "an 8 crew-hour job is not instant")

	# The coarse path, exactly as TickScheduler builds it: one hour per step,
	# channels sampled at the hour midpoint.
	var tick := sim.clock.tick_index
	var actual := -1
	for _hour in 200:
		var ctx := TimeContext.new()
		ctx.tick_index = tick
		ctx.dt_game_seconds = 3600
		ctx.mode = TimeContext.Mode.COARSE
		var hour_of_day := (tick * GameClock.GAME_SECONDS_PER_TICK / 60
				+ GameClock.FOUNDING_OFFSET_MINUTES) % GameClock.MINUTES_PER_DAY / 60
		ctx.channels_hour = {"construction_rate": sim.curves.channel_clamp(
				"construction_rate", sim.curves.channel_curve_value(
						"construction_rate", float(hour_of_day) + 0.5))}
		tick += GameClock.TICKS_PER_HOUR
		if not sim.construction.advance(ctx).is_empty():
			actual = tick
			break
	assert_true(actual > 0, "the job completed inside 200 game-hours")
	assert_true(predicted > actual - GameClock.TICKS_PER_HOUR and predicted <= actual,
			"predicted %d lands in the hour the queue finished (%d)" % [predicted, actual])


func test_06b_the_level_in_the_copy_is_the_level_the_job_delivers() -> void:
	# `Building.level` is 0 while a build is in progress, so reading it straight
	# would render "A Level 0 building came online." — which is what
	# `n_construction_complete_body` would have said on every first build.
	var sim := StubSim.new()
	var scheduler := _scheduler()
	# 30 crew-hours ≈ 37 game-hours at the `construction_rate` curve's own mean,
	# and a game-hour is a real minute — so this clears the 20-minute Doze floor
	# that a 4-hour job would have been dropped by.
	var build_id := sim.construction.submit(&"build", "B-1", 30.0,
			&"construction_crew", {"sim_id": "B-1"})
	sim.construction.assign_crew(build_id, "YARD-CREW-1")
	var entries := scheduler.collect(sim, NOW_UNIX)
	assert_eq(entries.size(), 1)
	assert_eq(int((entries[0]["args"] as Dictionary)["level"]), 1,
			"a new build delivers Level 1")


func test_07_a_job_with_no_crew_has_no_honest_completion_time() -> void:
	var sim := StubSim.new()
	var job_id := sim.construction.submit(&"build", "B-8", 4.0)
	var scheduler := _scheduler()
	assert_eq(scheduler.eta_tick(sim, sim.construction.job(job_id), 0), -1,
			"nobody is working on it, so no date is promised")
	assert_eq(scheduler.collect(sim, NOW_UNIX).size(), 0)


func test_08_repairs_and_roads_do_not_notify() -> void:
	# doc 08's table has a push row for a finished BUILDING and for developed
	# LAND. A repair takes minutes and a road is instant; a push for either would
	# spend one of eight daily tokens on nothing.
	var sim := StubSim.new()
	for kind: StringName in [&"repair", &"road", &"clear_rubble"]:
		var job_id := sim.construction.submit(kind, "X", 6.0)
		sim.construction.assign_crew(job_id, "YARD-CREW-1")
	assert_eq(_scheduler().collect(sim, NOW_UNIX).size(), 0)


# ===========================================================================
# doc 13 §2.4 class (b) — pre-rolled Director forecasts
# ===========================================================================

func test_09_a_pre_rolled_storm_warning_is_scheduled_at_its_lead() -> void:
	# doc 13 §2.4's worked example: onset at game-minute 13 920 with a 180-minute
	# warning lead → the warning fires at 13 740, which from 12 480 is 1 260 game
	# minutes = 1 260 real seconds = 21 real minutes. Just past the Doze floor,
	# which is exactly why the doc chose the number.
	var sim := StubSim.new()
	sim.clock.tick_index = 12_480 * TICKS_PER_MINUTE
	sim.director.rows = [{
		"event_id": 31, "kind": "severe_thunderstorm", "severity": 1.4,
		"onset_gmin": 13_920, "warning_lead_gmin": 180, "confidence": 1.0,
	}]
	var entries := _scheduler().collect(sim, NOW_UNIX)
	assert_eq(entries.size(), 1)
	assert_eq(str(entries[0]["notify_id"]), "weather_warning")
	assert_almost_eq(float(entries[0]["real_delay_s"]), 1_260.0, 0.001)
	assert_eq(int((entries[0]["args"] as Dictionary)["minutes"]), 180,
			"the copy says how much warning the player has")


func test_10_an_unwarned_director_event_is_a_surprise_not_a_forecast() -> void:
	var sim := StubSim.new()
	sim.clock.tick_index = 12_480 * TICKS_PER_MINUTE
	sim.director.rows = [
		{"event_id": 1, "kind": "grid_fault", "onset_gmin": 14_000,
			"warning_lead_gmin": 0, "confidence": 1.0},
		{"event_id": 2, "kind": "storm", "onset_gmin": 14_000,
			"warning_lead_gmin": 180, "confidence": 0.4},
	]
	assert_eq(_scheduler().collect(sim, NOW_UNIX).size(), 0,
			"no lead and low confidence are both silence, per doc 08 §2.13.0")


# ===========================================================================
# The router's offline pass
# ===========================================================================

func _sim_with_three_futures() -> StubSim:
	var sim := StubSim.new()
	sim.clock.tick_index = 0
	for i in 3:
		# 3.5 h, 7 h and 10.5 h of real delay. Each clears the Doze floor and sits
		# inside the 12 h cap, and — the spacing that actually matters — they are
		# 210 real minutes apart, which clears BOTH P3's 60-minute class gap and
		# `construction_complete`'s 180-minute key cooldown. That event is
		# `aggregate: true` in doc 08's table, so every completion shares one
		# cooldown key: three buildings finishing an hour apart is one story, and
		# the budget is right to collapse it.
		var due := int((12_600.0 * float(i + 1)) * 1000.0 / REAL_MS_PER_TICK)
		sim.timers.schedule(&"notification", &"test", due,
				{"notify_id": "construction_complete", "ref": "B-%d" % i,
					"args": {"level": i + 1}}, true)
	return sim


func test_11_pause_arms_one_alarm_per_accepted_plan_with_stable_ids() -> void:
	var native := FakeNative.new()
	var router := _router(native)
	var plans := router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	assert_eq(plans.size(), 3, "three predictable futures, three decisions")
	assert_eq(native.posted.size(), 3, "…and three alarms on the platform")
	# doc 13 §2.5: ids are unique within a batch, 1000 up, because cancel_all()
	# runs before every plan.
	var ids: Array = []
	for entry: Dictionary in native.posted:
		ids.append(int(entry["id"]))
	assert_eq(ids, [1000, 1001, 1002] as Array)
	# Fire times, not now times: an alarm carries the moment it should ring.
	assert_eq(int(native.posted[0]["fire_at_wall_ms"]),
			int(round((NOW_UNIX + 12_600.0) * 1000.0)))
	assert_true(int(native.posted[2]["fire_at_wall_ms"])
			> int(native.posted[0]["fire_at_wall_ms"]),
			"armed in fire order")


func test_12_the_copy_is_rendered_from_the_one_string_table() -> void:
	var native := FakeNative.new()
	var router := _router(native)
	router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	var first: Dictionary = native.posted[0]
	assert_eq(str(first["title"]), "Construction finished",
			"n_construction_complete_title, from data/strings.en.json (G-8)")
	assert_eq(str(first["body"]), "A Level 1 building came online.",
			"{level} filled from the entry's args")
	assert_false(str(first["body"]).contains("{"),
			"no unfilled placeholder ever reaches a lock screen")
	assert_eq(str(first["channel_id"]), "slacum_routine",
			"P3's channel, from doc 08's class table")


func test_13_resume_cancels_everything_and_gives_the_tokens_back() -> void:
	# The player comes back in five minutes: none of the three alarms rang, so
	# none of them may cost anything. Spending a token on a future that then did
	# not happen is the one way a schedule-at-pause design can quietly starve the
	# budget of a player who checks in often.
	var native := FakeNative.new()
	var router := _router(native)
	var before := router.budget().serialize()
	router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	assert_eq(router.offline_scheduled_count(), 3, "three futures armed")
	assert_ne(str(router.budget().serialize()), str(before),
			"planning spends: the buckets moved")

	var cancelled := router.replan_after_resume(NOW_UNIX + 300.0)  # back in 5 minutes
	assert_eq(cancelled, 3, "every pending alarm is dropped (doc 08 §2.13)")
	assert_eq(native.cancels, 1)
	# The whole budget, not just the token count: the timestamps that drive the
	# min-gaps were moved into the future too, and leaving them there would mute
	# the next real notification for hours.
	assert_eq(str(router.budget().serialize()), str(before),
			"…and the budget is byte-for-byte where it was")
	assert_eq(router.offline_scheduled_count(), 0)


func test_14_an_alarm_that_already_rang_keeps_costing_its_token() -> void:
	# …and the other half: a player who comes back after the first two fired
	# pays for two, not zero and not three. No delivery receipt is involved,
	# which matters because the receipt only exists when the process was alive.
	var native := FakeNative.new()
	var router := _router(native)
	var before := router.budget().serialize()
	router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	router.replan_after_resume(NOW_UNIX + 30_000.0)  # past the 3.5 h and 7 h ones
	var after := router.budget().serialize()
	assert_ne(str(after), str(before), "two of them rang; that is not free")
	# The second entry fires 25 200 real seconds in, and the third at 37 800 — so
	# the last spend on record has to be the second one's minute, not the third's.
	assert_almost_eq(float(after["last_any_min"]), (NOW_UNIX + 25_200.0) / 60.0, 0.001,
			"the cancelled alarm left no trace; the delivered ones did")
	assert_almost_eq(float(after["last_key_min"]["construction_complete"]),
			(NOW_UNIX + 25_200.0) / 60.0, 0.001)


func test_15_quiet_hours_are_judged_in_the_players_evening_not_ours() -> void:
	# The fire time is 14:00 UTC — the middle of the working day, and a perfectly
	# fine moment to buzz somebody in London. For a player nine hours east it is
	# 23:00, inside doc 08's 22:00–08:00 window, and the same alarm has to be
	# deferred to the morning summary instead. The device-local UTC offset is the
	# one input doc 08's planner cannot obtain from `sim/`, and doc 13 §2.5 item 1
	# exists to supply exactly this.
	var native := FakeNative.new()
	var router := _router(native)
	router.utc_offset_minutes = func() -> int: return 9 * 60
	var delay := 6.0 * 3_600.0
	assert_eq(router.minute_of_day_at(NOW_UNIX + delay), 23 * 60,
			"14:00 UTC is 23:00 for a player nine hours east")
	var sim := StubSim.new()
	sim.clock.tick_index = 0
	sim.timers.schedule(&"notification", &"test",
			int(delay * 1000.0 / REAL_MS_PER_TICK),
			{"notify_id": "construction_complete", "ref": "NIGHT"}, true)
	var plans := router.plan_offline(router.scheduler.collect(sim, NOW_UNIX), NOW_UNIX)
	assert_eq(plans.size(), 1)
	assert_false(bool(plans[0]["allowed"]))
	assert_eq(str(plans[0]["reason"]), NotificationBudget.REASON_QUIET_HOURS,
			"deferred to the 08:00 summary, not delivered at 02:00")
	assert_eq(native.posted.size(), 0)


# ===========================================================================
# The seam and the channels
# ===========================================================================

func test_16_three_channels_are_created_and_p4_is_not() -> void:
	# doc 13 §2.5 / test A-27. P4 has no channel while doc 08 ships it disabled:
	# an empty row in Android's own settings screen is a promise the game does
	# not keep.
	var native := FakeNative.new()
	_router(native)  # set_sink() creates the channels
	var ids: Array = []
	for channel: Dictionary in native.channels:
		ids.append(str(channel["id"]))
	assert_eq(ids, ["slacum_critical", "slacum_important", "slacum_routine"] as Array)
	assert_eq(str(native.channels[0]["importance"]), "high")
	assert_true(bool(native.channels[0]["vibrate"]), "P1 vibrates")
	assert_false(bool(native.channels[2]["sound"]), "P3 is silent")
	assert_ne(str(native.channels[0]["name"]), "P1_critical",
			"the channel wears a human name; it can never be renamed afterwards")


func test_17_without_the_plugin_the_whole_pipeline_still_decides() -> void:
	# Desktop, the headless runner, a prebuilt-template APK. Every plan is made,
	# every budget is spent, nothing buzzes, nothing crashes — which is what makes
	# the feature testable at all.
	var native := FakeNative.new()
	native.supports = false
	var router := _router(native)
	var plans := router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	assert_eq(plans.size(), 3, "the decisions are unchanged")
	for plan: Dictionary in plans:
		assert_true(bool(plan["allowed"]))
		assert_false(bool(plan["delivered"]), "…and none of them went anywhere")
	assert_eq(native.posted.size(), 0)


func test_18_a_denied_permission_records_the_plan_and_posts_nothing() -> void:
	var native := FakeNative.new()
	native.enabled = false  # the player said no, or turned the app's switch off
	var router := _router(native)
	router.plan_for_background(_sim_with_three_futures(), NOW_UNIX)
	assert_eq(native.posted.size(), 0)
	var sink: NativeNotificationSink = router.sink()
	assert_eq(sink.log_entries().size(), 3,
			"the seam still logs what it was asked to deliver")
	assert_false(sink.can_post())
	assert_true(sink.is_available(), "the platform is there; the permission is not")


func test_19_the_real_bridge_is_inert_off_device() -> void:
	var bridge := AndroidNative.detect()
	assert_false(bridge.supports_notifications())
	assert_false(bridge.notifications_enabled())
	assert_eq(bridge.permission_state(), AndroidNative.PERMISSION_UNSUPPORTED)
	assert_false(bridge.request_notification_permission())
	assert_false(bridge.post_notification({}))
	assert_false(bridge.schedule_notification(1, "t", "b", 0))
	assert_eq(bridge.cancel_notifications(), 0)
	assert_eq(bridge.scheduled_ids().size(), 0)
	assert_eq(bridge.consume_launch_payload(), "")


# ===========================================================================
# Copy (doc 13 §2.6: never state a time)
# ===========================================================================

func test_20_no_notification_copy_states_a_wall_clock_time() -> void:
	# Alarms are inexact by choice, so "at 19:00" would be a lie roughly one time
	# in four. "in about 3 hours" is true whenever it arrives.
	var store := NotificationText.load_from_files()
	assert_true(store.errors.is_empty(), str(store.errors))
	assert_eq(str(store.clock_time_offenders()), "[]",
			"no n_* string names a clock time (doc 13 §2.6)")


func test_21_a_missing_key_renders_as_itself_and_never_as_blank() -> void:
	var store := NotificationText.new({"n_x_title": "Hello {who}", "n_x_title_one": "Hi {who}"})
	assert_eq(store.render("n_x_title", {"who": "Slacum"}), "Hello Slacum")
	assert_eq(store.render("n_missing_title"), "n_missing_title",
			"visible and greppable beats an empty notification")
	var rendered := store.render_plan({"title_key": "n_x_title", "body_key": "n_none",
			"args": {"who": "you"}})
	assert_eq(str(rendered["title"]), "Hello you")
	assert_eq(str(rendered["body"]), "n_none")


func test_22_long_copy_is_clipped_to_what_android_will_show() -> void:
	var long_body := "x".repeat(400)
	var store := NotificationText.new({"n_x_body": long_body})
	var rendered := store.render_plan({"title_key": "", "body_key": "n_x_body"})
	assert_eq(str(rendered["body"]).length(), NotificationText.BODY_MAX)
	assert_true(str(rendered["body"]).ends_with("…"))


# ===========================================================================
# doc 13 §2.7 — the permission flow, whose job is to not ask
# ===========================================================================

func _flow(native: FakeNative) -> PermissionFlow:
	var flow := PermissionFlow.new(native)
	flow.wall_clock = func() -> float: return NOW_UNIX
	return flow


func test_23_nothing_is_asked_before_there_is_something_to_schedule() -> void:
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_NEVER_ASKED
	var flow := _flow(native)
	assert_false(flow.should_prompt(NOW_UNIX),
			"a cold prompt at launch burns one of the two chances Android allows")
	flow.note_trigger()
	assert_true(flow.should_prompt(NOW_UNIX))
	assert_eq(flow.request_rationale(NOW_UNIX), PermissionFlow.REASON_FIRST)


func test_24_declining_costs_a_chance_and_ends_the_session() -> void:
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_NEVER_ASKED
	var flow := _flow(native)
	flow.note_trigger()
	flow.decline(NOW_UNIX)
	native.permission = AndroidNative.PERMISSION_DENIED
	assert_eq(flow.asked_count, 1)
	assert_false(flow.should_prompt(NOW_UNIX), "not twice in one session")


func test_25_a_second_prompt_needs_seven_days_and_something_to_say() -> void:
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_DENIED
	var flow := _flow(native)
	flow.note_trigger()
	flow.asked_count = 1
	flow.last_asked_unix = int(NOW_UNIX)
	var week := NOW_UNIX + PermissionFlow.REPROMPT_COOLDOWN_S + 1.0
	assert_false(flow.should_prompt(week),
			"seven days is necessary and not sufficient — there is nothing to say yet")
	flow.note_missed_p1()
	assert_false(flow.should_prompt(NOW_UNIX + 3_600.0), "…and an hour is not seven days")
	assert_true(flow.should_prompt(week))
	assert_eq(flow.request_rationale(week), PermissionFlow.REASON_MISSED_P1,
			"'You missed a citywide blackout' — evidence, not a nag")


func test_26_two_refusals_are_final() -> void:
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_DENIED
	var flow := _flow(native)
	flow.note_trigger()
	flow.asked_count = 2
	flow.reprompt_count = PermissionFlow.REPROMPT_MAX
	flow.note_missed_p1()
	assert_false(flow.should_prompt(NOW_UNIX + 10.0 * 86_400.0))


func test_27_a_permanently_denied_app_offers_settings_instead() -> void:
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_DENIED_PERMANENT
	var flow := _flow(native)
	flow.note_trigger()
	flow.note_missed_p1()
	assert_false(flow.should_prompt(NOW_UNIX + 30.0 * 86_400.0),
			"Android has stopped showing the dialog; a modal here opens nothing")
	assert_eq(flow.settings_row_state(), "blocked")
	assert_true(flow.open_system_settings())
	assert_eq(native.settings_opened, 1)


func test_28_off_device_the_flow_is_silent_and_survives_a_round_trip() -> void:
	var native := FakeNative.new()
	native.available = false
	var flow := _flow(native)
	flow.note_trigger()
	assert_eq(flow.state(), AndroidNative.PERMISSION_UNSUPPORTED)
	assert_false(flow.should_prompt(NOW_UNIX))
	assert_eq(flow.settings_row_state(), "unavailable")

	flow.asked_count = 2
	flow.last_asked_unix = 1_700_000_000
	flow.reprompt_count = 1
	var restored := PermissionFlow.new(native)
	restored.deserialize(flow.serialize())
	assert_eq(restored.asked_count, 2)
	assert_eq(restored.last_asked_unix, 1_700_000_000)
	assert_eq(restored.reprompt_count, 1)


# ===========================================================================
# PA-14 · A91-D-69 — the two seams that were missing, as the shell has them
# ===========================================================================
#
# `PermissionShellMirror` below is `game/main.gd`'s two batch hooks, verbatim
# apart from the field names a test can reach — the same arrangement
# `ShellResumeRig` uses and for the same reason: `main.gd` is the lead's file
# and this branch delivers its changes as snippets, so the only place the
# ORDERING is executable without a window is here.

class PermissionShellMirror extends RefCounted:
	const PERMISSION_TRIGGERS: Array[StringName] = [
		&"upgrade_started_sim",
		&"incident_resolved",
	]
	const PERMISSION_EVIDENCE_RANK := 1

	var permission_flow: PermissionFlow
	var notification_router: NotificationRouter

	func _note_permission_trigger(batch: Array) -> void:
		if permission_flow == null or permission_flow.triggered:
			return
		for raw: Variant in batch:
			if not (raw is Dictionary):
				continue
			if PERMISSION_TRIGGERS.has(StringName(String(
					(raw as Dictionary).get("type", "")))):
				permission_flow.note_trigger()
				return

	func _note_permission_evidence(plans: Array) -> void:
		if permission_flow == null or notification_router == null:
			return
		if permission_flow.notifications_enabled():
			return
		for raw: Variant in plans:
			if not (raw is Dictionary):
				continue
			var class_id := str((raw as Dictionary).get("class", ""))
			if notification_router.config().class_rank(class_id) \
					== PERMISSION_EVIDENCE_RANK:
				permission_flow.note_missed_p1()
				return


func _mirror(native: FakeNative) -> PermissionShellMirror:
	var mirror := PermissionShellMirror.new()
	mirror.permission_flow = _flow(native)
	mirror.notification_router = _router(native)
	return mirror


func test_30_the_trigger_is_the_first_timer_the_player_chose_never_the_launch()\
		-> void:
	# Doc 13 §2.7 step 1 ("the first construction timer") and doc 08 §2.13.4
	# ("the first resolved incident"). Neither is launch, and neither is the
	# house the tutorial has the player place in its first minute — that is the
	# cold prompt with extra steps.
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_NEVER_ASKED
	var mirror := _mirror(native)

	mirror._note_permission_trigger([
		{"type": "building_placed_sim", "sim_id": "B-7"},
		{"type": "economy_hour_settled", "net": 120.0},
		{"type": "weather_changed", "state": "rain"}])
	assert_false(mirror.permission_flow.triggered,
			"a placed house and an hour of weather are not a reason to ask")
	assert_false(mirror.permission_flow.should_prompt(NOW_UNIX))

	mirror._note_permission_trigger([{"type": "upgrade_started_sim", "sim_id": "B-7"}])
	assert_true(mirror.permission_flow.triggered, "the first construction timer is")
	assert_true(mirror.permission_flow.should_prompt(NOW_UNIX))

	var by_incident := _mirror(FakeNative.new())
	by_incident.permission_flow.native.permission = AndroidNative.PERMISSION_NEVER_ASKED
	by_incident._note_permission_trigger([{"type": "incident_resolved", "incident_id": 3}])
	assert_true(by_incident.permission_flow.triggered, "…and so is the first fix")


func test_31_a_second_prompt_is_earned_by_a_p1_the_player_never_heard() -> void:
	# doc 13 §2.7 step 7's evidence, read off the router's own classification so
	# the shell holds no second copy of doc 08's class table.
	var heard := FakeNative.new()          # the permission IS held
	var heard_mirror := _mirror(heard)
	heard_mirror._note_permission_evidence(
			heard_mirror.notification_router.feed_batch(
					[{"type": "incident_failed", "incident_id": 9,
						"incident_type": "fire", "tier_peak": 4}]))
	assert_false(heard_mirror.permission_flow.missed_p1_offline,
			"a P1 that DID buzz is not a reason to ask for anything")

	var unheard := FakeNative.new()
	unheard.enabled = false                # …and here it is not
	unheard.permission = AndroidNative.PERMISSION_DENIED
	var mirror := _mirror(unheard)
	mirror._note_permission_evidence(mirror.notification_router.feed_batch(
			[{"type": "economy_hour_settled", "net": 12.0}]))
	assert_false(mirror.permission_flow.missed_p1_offline, "a settled hour is not a P1")
	mirror._note_permission_evidence(mirror.notification_router.feed_batch(
			[{"type": "incident_failed", "incident_id": 9,
				"incident_type": "fire", "tier_peak": 4}]))
	assert_true(mirror.permission_flow.missed_p1_offline)

	# …and the evidence is only half of what a re-prompt costs.
	mirror.permission_flow.note_trigger()
	mirror.permission_flow.asked_count = 1
	mirror.permission_flow.last_asked_unix = int(NOW_UNIX)
	assert_false(mirror.permission_flow.should_prompt(NOW_UNIX + 3_600.0),
			"an hour is not seven days")
	assert_eq(mirror.permission_flow.request_rationale(
			NOW_UNIX + PermissionFlow.REPROMPT_COOLDOWN_S + 1.0),
			PermissionFlow.REASON_MISSED_P1)


func test_32_the_permission_bookkeeping_is_device_scoped_not_city_scoped() -> void:
	# The correctness argument, not a convenience: Android's two dismissals are
	# spent per INSTALL. A counter that rode in the city's save would hand a
	# player who deleted their city a third prompt the system will not show, and
	# the modal would open a dialog that never appears.
	var path := "user://test_permission_%d.cfg" % Time.get_ticks_usec()
	var native := FakeNative.new()
	native.permission = AndroidNative.PERMISSION_DENIED
	var flow := _flow(native)
	flow.note_trigger()
	flow.decline(NOW_UNIX)
	assert_eq(flow.asked_count, 1)
	assert_true(flow.save_device(path))

	var relaunched := PermissionFlow.new(native)
	relaunched.load_device(path)
	assert_eq(relaunched.asked_count, 1, "the chance stayed spent across a relaunch")
	assert_eq(relaunched.last_asked_unix, int(NOW_UNIX))
	# The settings row is the only surface a denied player has left.
	assert_eq(relaunched.settings_row_state(), "off")
	native.permission = AndroidNative.PERMISSION_DENIED_PERMANENT
	assert_eq(relaunched.settings_row_state(), "blocked")


# ===========================================================================
# The lifecycle wiring (doc 13 §2.2)
# ===========================================================================

func test_29_pause_plans_and_resume_cancels_through_the_lifecycle_node() -> void:
	var native := FakeNative.new()
	var router := _router(native)
	var lifecycle := AndroidLifecycle.new()
	lifecycle.native = FakeNative.new()
	lifecycle.notification_router = router
	lifecycle.sim = _sim_with_three_futures()
	lifecycle.wall_clock = func() -> float: return NOW_UNIX
	lifecycle.mono_clock = func() -> float: return 100.0

	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_eq(lifecycle.last_planned, 3, "the pause sequence planned the absence")
	assert_eq(native.posted.size(), 3)

	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(lifecycle.last_cancelled, 3, "…and the resume cancelled it")
	assert_eq(native.posted.size(), 0)
	lifecycle.free()


func test_29b_an_in_session_event_posts_immediately_at_pause() -> void:
	# The other half of the pause pass, and the one that changed the day the sink
	# came alive: a P1 that fired while the player was watching is flushed as the
	# app goes away, and now that there is a platform underneath it, it POSTS —
	# with no `fire_at_wall_ms`, so it is a notification and not an alarm.
	#
	# Whether that is the right call is a policy question (doc 13 §11.10 raises
	# it: it spends a token the offline plan then does not have). What is not in
	# question is the mechanism, and this pins the mechanism.
	var native := FakeNative.new()
	var router := _router(native)
	router.feed({"type": "incident_created", "incident_id": 7,
			"incident_type": "structure_fire", "tier": 3,
			"notification_priority": 1})
	assert_eq(router.pending_count(), 1, "queued, not yet decided")
	var plans := router.plan_for_background(null, NOW_UNIX)
	assert_eq(plans.size(), 1, "the pause pass decided it")
	assert_true(bool(plans[0]["allowed"]))
	assert_eq(native.posted.size(), 1)
	assert_eq(int(native.posted[0]["fire_at_wall_ms"]), 0,
			"no fire time: posted now, not armed for later")
	assert_eq(str(native.posted[0]["channel_id"]), "slacum_critical")


func test_30_settings_rows_write_doc_08s_switches_and_only_those() -> void:
	var native := FakeNative.new()
	var router := _router(native)
	assert_eq(NotificationRouter.setting_key_for("P1_critical"), "notify_p1_critical",
			"the row key IS the class id, so ui.json and notifications.json cannot drift")
	router.apply_settings({"notifications_enabled": true, "notify_p1_critical": false,
			"notify_p2_important": true, "notify_p3_routine": true,
			"quiet_hours_allow_critical": true})
	assert_false(router.budget().class_enabled("P1_critical"))
	assert_true(router.budget().class_enabled("P3_routine"))
	assert_true(router.budget().allow_critical_in_quiet())

	router.apply_settings({"notifications_enabled": false, "notify_p1_critical": true})
	for class_id: String in router.config().class_ids():
		assert_false(router.budget().class_enabled(class_id),
				"the master switch outranks every row (%s)" % class_id)

	router.apply_settings({"notifications_enabled": true, "notify_p4_ambient": true})
	assert_false(router.budget().class_enabled("P4_ambient"),
			"a class doc 08 ships disabled can never be switched on from a settings row")


func test_31_every_settings_row_the_router_reads_exists_in_the_ui_table() -> void:
	# The two files have to agree by construction, so this asserts the join
	# rather than the contents: every class doc 08 ships enabled has a row, and
	# every row's copy exists.
	var cfg := UIConfig.load_from_files()
	var rows: Variant = cfg.section("settings").get("rows", [])
	var keys: Array = []
	for raw: Variant in (rows as Array if rows is Array else []):
		if raw is Dictionary:
			keys.append(str((raw as Dictionary).get("key", "")))
	assert_true(keys.has(NotificationRouter.SETTING_MASTER))
	assert_true(keys.has(NotificationRouter.SETTING_QUIET_CRITICAL))
	var notifications := _cfg()
	for class_id: String in notifications.class_ids():
		var key := NotificationRouter.setting_key_for(class_id)
		if not notifications.class_enabled(class_id):
			assert_false(keys.has(key), "%s ships disabled and has no row" % class_id)
			continue
		assert_true(keys.has(key), "%s has an S10 row" % class_id)
		assert_true(cfg.has_string("ui_settings_row_%s" % key),
				"%s has a label" % key)
