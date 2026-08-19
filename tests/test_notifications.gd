extends SimTest
## doc 08 §2.13 / §3.3 — the notification platform: `data/notifications.json`,
## `game/notifications/*`, and the ingest swap in `ui/alerts_model.gd`.
##
## The events fed here are the **actual dictionaries** `sim/` emits, checked
## against their emit sites, so a rename on either side fails this file rather
## than going quietly un-notified. That is not a stylistic choice: the table this
## file replaced read `city_level_changed.level` and `block_ready.block_id` while
## the sim emitted `to` and `block`, and both notifications rendered an empty
## title in the real game for as long as the tests fed them fixtures.
##
## What is load-bearing here, and why each is a test:
##   * one table, two readers — the in-app feed and the push plan can never
##     disagree about what class an event is,
##   * the token buckets are doc 08 §2.13.2's arithmetic, to the minute,
##   * quiet hours WRAP midnight, bypass is hard to earn, and what they swallow
##     comes back as one summary rather than being lost,
##   * a denial is recorded with a reason and never dropped,
##   * the sink seam is inert and complete.

const NOTIFICATIONS_JSON := "res://data/notifications.json"
## 22:00 and 09:00 in device-local minutes past midnight — inside and outside
## the shipped quiet window.
const NIGHT := 22 * 60
const MORNING := 9 * 60


func _cfg() -> NotificationConfig:
	return NotificationConfig.load_from_files()


## A router on a fixed clock. `minutes` is real minutes since an arbitrary
## epoch and `minute_of_day` is the device-local wall clock — the only two
## numbers doc 08's policy needs, and both injected so no test reads `Time`.
func _router(sink: NotificationSink = null) -> NotificationRouter:
	var router := NotificationRouter.new(_cfg(), sink)
	router.wall_clock = func() -> float: return _clock_minutes
	router.local_minute_of_day = func() -> int: return _clock_minute_of_day
	return router


var _clock_minutes := 0.0
var _clock_minute_of_day := MORNING


func _at(minutes: float, minute_of_day: int = -1) -> void:
	_clock_minutes = minutes
	if minute_of_day >= 0:
		_clock_minute_of_day = minute_of_day


func _budget() -> NotificationBudget:
	return NotificationBudget.new(_cfg())


# ===========================================================================
# The table
# ===========================================================================

func test_01_the_table_parses_and_every_binding_names_a_real_event() -> void:
	var cfg := _cfg()
	assert_true(cfg.is_valid(), "data/notifications.json parses: %s" % str(cfg.errors))
	assert_eq(int(cfg.data().get("schema_version", 0)), 1)
	assert_true(cfg.bindings().size() >= 20,
			"the table covers the game, not a sample: %d bindings" % cfg.bindings().size())

	var rules := cfg.alert_rules()
	assert_eq(rules.size(), cfg.bindings().size(),
			"every binding survived the merge: %s" % str(cfg.errors))
	for raw: Variant in rules:
		var rule: Dictionary = raw
		var notify_id := str(rule["notify_id"])
		assert_false(cfg.event_def(notify_id).is_empty(),
				"binding for %s names a real event row" % str(rule["type"]))
		assert_true(["p1", "p2", "p3"].has(str(rule["class"])),
				"%s maps onto one of doc 12's surface classes" % notify_id)
		assert_true(cfg.class_ids().has(str(rule["push_class"])),
				"%s names a real push class" % notify_id)


func test_02_the_four_classes_are_doc_08s_and_p4_ships_silent() -> void:
	var cfg := _cfg()
	assert_eq(cfg.class_ids(),
			["P1_critical", "P2_important", "P3_routine", "P4_ambient"] as Array[String],
			"four classes, in rank order")
	# §2.13.1's table, held as data rather than as prose.
	var expected := {
		"P1_critical": [2, 60, 10], "P2_important": [3, 360, 20],
		"P3_routine": [4, 1440, 60], "P4_ambient": [1, 2880, 720],
	}
	for class_id: String in expected:
		var row := cfg.class_def(class_id)
		var want: Array = expected[class_id]
		assert_eq(AudioConfig.get_int(row, "capacity", -1), int(want[0]),
				"%s capacity" % class_id)
		assert_eq(AudioConfig.get_int(row, "window_minutes", -1), int(want[1]),
				"%s window" % class_id)
		assert_eq(AudioConfig.get_int(row, "min_gap_minutes", -1), int(want[2]),
				"%s min gap" % class_id)
		assert_ne(str(row.get("channel_id", "")), "",
				"%s names a stable Android channel (spec §49)" % class_id)
	assert_true(cfg.class_enabled("P1_critical"))
	assert_false(cfg.class_enabled("P4_ambient"),
			"P4 exists in schema and emits nothing in MVP (report C-71)")


func test_03_the_push_budget_is_far_tighter_than_the_in_app_one() -> void:
	# Report C-72: doc 12's in-app rates are ~3x these and are a DIFFERENT
	# quantity. If this ever inverts, somebody has read the wrong file.
	var cfg := _cfg()
	var ui := UIConfig.load_from_files()
	var in_app: Dictionary = ui.section("in_app_alerts")
	var classes: Variant = in_app.get("classes", {})
	assert_true(classes is Dictionary and not (classes as Dictionary).is_empty(),
			"data/ui.json still carries doc 12's foreground gate")
	var p1_in_app := float((((classes as Dictionary)["p1"]) as Dictionary)["refill_per_real_hour"])
	var p1_push := 60.0 * float(AudioConfig.get_int(cfg.class_def("P1_critical"), "capacity", 0)) \
			/ float(AudioConfig.get_int(cfg.class_def("P1_critical"), "window_minutes", 1))
	assert_true(p1_push < p1_in_app,
			"a push costs attention the player is not already giving: %.2f/h vs %.2f/h"
			% [p1_push, p1_in_app])
	assert_eq(str(in_app.get("class_map_from", "")), "data/notifications.json",
			"and ui.json points at this file for the class map")


func test_04_ui_json_no_longer_carries_an_event_table() -> void:
	# The stand-in was REPLACED wholesale, never merged: two tables would be two
	# answers to "what class is this", which is exactly what C-71 forbids.
	var ui := UIConfig.load_from_files()
	var alerts := ui.section("alerts")
	assert_false(alerts.is_empty(), "the presentation block survives")
	assert_false(alerts.has("events"),
			"but its event list is gone — doc 08's file owns that now")
	assert_true(alerts.has("row_h_dp") and alerts.has("panel_w_dp"),
			"what is left is how wide the panel is, not what the player is told")


# ===========================================================================
# The in-app feed reads the new file
# ===========================================================================

func test_05_the_alerts_model_ingests_doc_08s_table() -> void:
	var model := AlertsModel.load_from_files()
	model.set_clock(372, 2)
	assert_eq(model.notification_errors().size(), 0,
			"the table loaded clean: %s" % str(model.notification_errors()))

	var dark := model.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true, "dark_fraction": 1.0})
	assert_eq(str(dark["notify_id"]), "outage_major")
	assert_eq(str(dark["push_class"]), "P1_critical", "doc 08's own class name")
	assert_eq(str(dark["class"]), "p1", "and doc 12's surface key for the same row")
	assert_eq(int(dark["severity"]), 4)

	# One table, two readers, one answer.
	var router := _router()
	var candidate := router.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true, "dark_fraction": 1.0})
	assert_eq(str(candidate["class"]), str(dark["push_class"]),
			"the feed row and the push plan agree about the class")
	assert_eq(int(candidate["severity"]), int(dark["severity"]))
	assert_eq(str(candidate["title_key"]), str(dark["title_key"]),
			"and about the copy keys (G-8)")


func test_06_the_events_the_stand_in_table_got_wrong_now_render() -> void:
	# Both of these rendered an EMPTY title in the shipped game: the table read a
	# field the sim does not emit, the sentence kept its hole, and the hole rule
	# dropped it. Fed here with the payload from the emit site.
	var cfg := UIConfig.load_from_files()
	var model := AlertsModel.new(cfg)
	model.set_clock(372, 2)

	var level := model.feed({"type": &"city_level_changed", "from": 2, "to": 3})
	assert_ne(str(level["title"]), "", "sim/population/progression_system.gd emits `to`")
	assert_true(str(level["title"]).contains("3"), "and the title says 3: %s" % level["title"])

	var land := model.feed({"type": &"block_ready", "block": "E4"})
	assert_ne(str(land["title"]), "", "sim/world/development_controller.gd emits `block`")
	assert_true(str(land["title"]).contains("E4"), "…and names it: %s" % land["title"])


func test_07_the_dead_strings_are_wired_now() -> void:
	# doc 05's water set, doc 06's incidents, doc 10's roads and doc 07's warning
	# all had `n_*` copy in data/strings.en.json and no rule to reach it. Doc 08's
	# table is where they finally get one.
	var model := AlertsModel.load_from_files()
	model.set_clock(372, 2)
	var expected := {
		"water_main_break": "water_main_break",
		"water_zone_offline": "water_zone_offline",
		"water_contamination_started": "water_contamination",
		"incident_created": "incident_started",
		"incident_failed": "incident_failed",
		"road_collapsed": "road_collapsed",
		"weather_warning": "weather_warning",
	}
	var payloads := {
		"water_main_break": {"edge": "M-12", "severity": 0.6, "damage_fraction": 0.4},
		"water_zone_offline": {"zone": "Z1", "dead": true},
		"water_contamination_started": {"zone": "Z3", "until_minutes": 900},
		"incident_created": {"incident_id": 3, "incident_type": "structure_fire",
			"tile": [10, 10], "severity": 0.4, "tier": 2, "notification_priority": 2},
		"incident_failed": {"incident_id": 4, "incident_type": "structure_fire",
			"tier_peak": 3},
		"road_collapsed": {"tile": Vector2i(4, 9), "road_class": "local"},
		"weather_warning": {"event_uid": 7, "kind": "severe_thunderstorm",
			"impact_min": 40, "lead_min": 25, "notify_class": "CRITICAL", "priority": 1},
	}
	for event_type: String in expected:
		var payload: Dictionary = (payloads[event_type] as Dictionary).duplicate()
		payload["type"] = StringName(event_type)
		var row := model.feed(payload)
		assert_false(row.is_empty(), "%s is notifiable now" % event_type)
		assert_eq(str(row["notify_id"]), str(expected[event_type]))
		assert_ne(str(row["title"]), "", "%s renders a title" % event_type)
		assert_false(str(row["title"]).contains("{"), "no hole in %s" % row["title"])


func test_08_an_incidents_own_priority_picks_its_budget() -> void:
	# `notification_priority` is doc 06's urgency and it is already the field
	# data/audio.json picks the sting from. Here it moves the same notify_id
	# between doc 08 budgets — one sentence, two levels of interruption.
	var model := AlertsModel.load_from_files()
	model.set_clock(372, 2)
	var routine := model.feed({"type": &"incident_created", "incident_id": 1,
			"incident_type": "structure_fire", "tile": [4, 4], "severity": 0.3,
			"tier": 1, "notification_priority": 3})
	var critical := model.feed({"type": &"incident_created", "incident_id": 2,
			"incident_type": "structure_fire", "tile": [9, 9], "severity": 0.9,
			"tier": 4, "notification_priority": 1})
	assert_eq(str(routine["notify_id"]), str(critical["notify_id"]),
			"the same event and the same copy")
	assert_eq(str(routine["push_class"]), "P2_important")
	assert_eq(str(critical["push_class"]), "P1_critical", "but not the same budget")


# ===========================================================================
# Token buckets — doc 08 §2.13.2, to the minute
# ===========================================================================

func test_09_buckets_start_full_and_are_spent_one_at_a_time() -> void:
	var budget := _budget()
	assert_almost_eq(budget.tokens("P1_critical"), 2.0, 0.001, "capacity 2")
	assert_almost_eq(budget.global_tokens(), 8.0, 0.001, "global capacity 8")

	# Two P1s, ten minutes apart (the class min gap), spend both tokens.
	assert_eq(budget.request("P1_critical", 4, "a", 0.0, 0.0, MORNING),
			NotificationBudget.REASON_OK)
	assert_almost_eq(budget.tokens("P1_critical"), 1.0, 0.001)
	assert_almost_eq(budget.global_tokens(), 7.0, 0.001, "both buckets pay")
	assert_eq(budget.request("P1_critical", 4, "b", 0.0, 10.0, MORNING),
			NotificationBudget.REASON_OK)
	# The third is refused by the bucket: refill is 2 per 60 min, so ten minutes
	# bought back 0.33 of a token and there is not one to spend.
	assert_eq(budget.request("P1_critical", 4, "c", 0.0, 20.0, MORNING),
			NotificationBudget.REASON_CLASS_BUCKET,
			"two per hour means two per hour")
	# …and it comes back on its own, at exactly the doc's rate.
	assert_eq(budget.request("P1_critical", 4, "c", 0.0, 50.0, MORNING),
			NotificationBudget.REASON_OK, "30 min at 2/60 min is one token")


func test_10_refill_is_continuous_and_survives_being_asked_twice() -> void:
	var budget := _budget()
	for i in 4:
		budget.request("P3_routine", 1, "k%d" % i, 0.0, 60.0 * float(i), MORNING)
	assert_almost_eq(budget.tokens("P3_routine"), 0.5, 0.02,
			"four sent over three hours, refilling at 4 per 24 h")
	# Idempotent within a minute: asking the budget a question must not refill it.
	var before := budget.tokens("P3_routine")
	for i in 20:
		budget.refill(180.0)
		budget.check("P3_routine", 1, "x", 0.0, 180.0, MORNING)
	assert_almost_eq(budget.tokens("P3_routine"), before, 0.0001,
			"twenty questions cost nothing and earn nothing")
	# An absence refills exactly as much as the same time in the foreground —
	# the app is not running for most of a bucket's window, so this is the
	# property that makes the limit mean anything.
	budget.refill(180.0 + 1440.0)
	assert_almost_eq(budget.tokens("P3_routine"), 4.0, 0.001, "a day away refills it")


func test_11_the_gaps_and_the_per_key_cooldown_bite_in_doc_order() -> void:
	var budget := _budget()
	assert_eq(budget.request("P2_important", 3, "transformer_failed/T-04", 120.0,
			0.0, MORNING), NotificationBudget.REASON_OK)
	# Global min gap (5 min) refuses ANY class first.
	assert_eq(budget.request("P3_routine", 1, "other", 0.0, 2.0, MORNING),
			NotificationBudget.REASON_GLOBAL_GAP, "5 minutes between any two")
	# Past it, a different class goes.
	assert_eq(budget.request("P3_routine", 1, "other", 0.0, 6.0, MORNING),
			NotificationBudget.REASON_OK)
	# The same class is still inside its own 20-minute gap.
	assert_eq(budget.request("P2_important", 3, "another", 0.0, 12.0, MORNING),
			NotificationBudget.REASON_CLASS_GAP)
	# And the same KEY is inside its 120-minute cooldown even when everything
	# else has cleared — one transformer is one story for two hours.
	assert_eq(budget.request("P2_important", 3, "transformer_failed/T-04", 120.0,
			40.0, MORNING), NotificationBudget.REASON_KEY_COOLDOWN)
	assert_eq(budget.request("P2_important", 3, "transformer_failed/T-09", 120.0,
			40.0, MORNING), NotificationBudget.REASON_OK,
			"a DIFFERENT transformer is a different story")


func test_12_the_global_bucket_is_the_backstop() -> void:
	# Eight per 1440 minutes, across every class at once — the last line of
	# defence when a city is falling apart in three subsystems and none of the
	# per-class limits has been reached. A full bucket plus a full day of refill
	# is 16, and that is the honest ceiling for the WORST day the game can have.
	var budget := _budget()
	# 21-minute steps rotating three classes puts each class 63 minutes apart,
	# clear of every class min gap (10 / 20 / 60) and of the 5-minute global one,
	# so the ONLY thing that can refuse a request here is a bucket.
	var sent := 0
	var hit_global := false
	for i in 68:
		var minute := 21.0 * float(i)
		var class_id: String = ["P1_critical", "P2_important", "P3_routine"][i % 3]
		var reason := budget.request(class_id, 4, "k%d" % i, 0.0, minute, MORNING)
		if reason == NotificationBudget.REASON_OK:
			sent += 1
		elif reason == NotificationBudget.REASON_GLOBAL_BUCKET:
			hit_global = true
	assert_true(hit_global,
			"the global bucket is what refuses once the classes stop being the limit")
	assert_true(sent <= 16,
			"a full bucket plus a day of refill, and no more: %d" % sent)
	assert_true(sent >= 8, "…but the day's whole allowance was available: %d" % sent)
	assert_true(budget.global_tokens() < 1.0, "and it ends the day empty")


func test_13_a_disabled_class_and_the_player_switch() -> void:
	var budget := _budget()
	assert_eq(budget.request("P4_ambient", 0, "reengagement", 0.0, 0.0, MORNING),
			NotificationBudget.REASON_CLASS_DISABLED,
			"P4 ships disabled and emits nothing (report C-71)")
	budget.set_class_enabled("P4_ambient", true)
	assert_false(budget.class_enabled("P4_ambient"),
			"and cannot be switched on: there is no channel to deliver it")

	budget.set_class_enabled("P2_important", false)
	assert_eq(budget.request("P2_important", 3, "k", 0.0, 0.0, MORNING),
			NotificationBudget.REASON_CLASS_DISABLED,
			"a player who turned a class off stays off")
	assert_almost_eq(budget.tokens("P2_important"), 3.0, 0.001,
			"and a refusal costs no token")


# ===========================================================================
# Quiet hours — doc 08 §2.13.3
# ===========================================================================

func test_14_the_quiet_window_wraps_midnight() -> void:
	var budget := _budget()
	# 22:00-08:00 device-local. The wrap is the whole difficulty: a naive
	# `start <= t < end` is quiet from 08:00 to 22:00, i.e. exactly backwards.
	for minute: int in [22 * 60, 23 * 60, 0, 3 * 60, 7 * 60 + 59]:
		assert_true(budget.in_quiet_window(minute),
				"%02d:%02d is inside the window" % [minute / 60, minute % 60])
	for minute: int in [8 * 60, 12 * 60, 19 * 60, 21 * 60 + 59]:
		assert_false(budget.in_quiet_window(minute),
				"%02d:%02d is outside it" % [minute / 60, minute % 60])


func test_15_the_quiet_bypass_takes_three_things_and_ships_off() -> void:
	var budget := _budget()
	assert_false(budget.allow_critical_in_quiet(),
			"'Allow critical alerts during quiet hours' ships OFF")
	# Even a severity-4 P1 is blocked while the switch is off.
	assert_true(budget.blocked_by_quiet_hours("P1_critical", 4, NIGHT))
	budget.set_allow_critical_in_quiet(true)
	assert_false(budget.blocked_by_quiet_hours("P1_critical", 4, NIGHT),
			"with the switch on, a severity-4 P1 gets through")
	assert_true(budget.blocked_by_quiet_hours("P1_critical", 3, NIGHT),
			"but a severity-3 P1 does not — the class names a floor and it is 4")
	assert_true(budget.blocked_by_quiet_hours("P2_important", 4, NIGHT),
			"and no other class has a floor a real severity can reach")
	assert_false(budget.blocked_by_quiet_hours("P2_important", 4, MORNING),
			"outside the window nothing is blocked by it")


func test_16_doc_08s_worked_example_comes_out_the_way_the_doc_says() -> void:
	# §2.13.3, verbatim: 03:10 real, a transformer_failed (P2), last P2 sent 15
	# minutes ago against a 20-minute gap, quiet hours active.
	# → min-gap fails AND quiet hours blocks ⇒ suppressed.
	var budget := _budget()
	budget.request("P2_important", 3, "transformer_failed/T-01", 120.0, 0.0, MORNING)
	var reason := budget.request("P2_important", 3, "transformer_failed/T-12", 120.0,
			15.0, 3 * 60 + 10)
	assert_eq(reason, NotificationBudget.REASON_CLASS_GAP,
			"the min gap is what refuses it first, and quiet hours would have too")
	assert_true(budget.blocked_by_quiet_hours("P2_important", 3, 3 * 60 + 10),
			"…which it does: 03:10 is inside the window and P2 has no bypass")


func test_17_what_quiet_hours_swallow_comes_back_as_one_summary() -> void:
	# `defer_to_end`: suppressed notifications collapse into a SINGLE P3 at the
	# end of the window. Nothing is lost — only un-buzzed.
	var router := _router()
	_at(0.0, NIGHT)
	router.flush()   # establish that the window is open
	for i in 3:
		_at(float(i) * 30.0, NIGHT)
		router.feed({"type": &"PowerComponentFailed", "component": "T-%02d" % i,
				"cause": "overload"})
		router.flush()
	assert_true(router.deferred_count() > 0, "the night swallowed them")
	for plan: Dictionary in router.plans():
		assert_false(bool(plan["allowed"]))
	assert_eq(str((router.plans()[0] as Dictionary)["reason"]),
			NotificationBudget.REASON_QUIET_HOURS)

	# 08:00: the window closes and one summary reports the night.
	_at(600.0, MORNING)
	var released := router.flush()
	assert_eq(released.size(), 1, "ONE summary, not three notifications")
	var summary: Dictionary = released[0]
	assert_eq(str(summary["notify_id"]), "quiet_hours_summary")
	assert_eq(str(summary["class"]), "P3_routine",
			"a rank BELOW the things it reports: they were not urgent enough to wake anyone")
	assert_eq(int(summary["count"]), 3, "and it says how many")
	assert_eq(router.deferred_count(), 0)

	# It does not fire again on the next flush.
	_at(660.0, MORNING)
	assert_eq(router.flush().size(), 0, "the window only closes once")


# ===========================================================================
# Coalescing — doc 08 §2.13.2
# ===========================================================================

func test_18_three_of_a_class_in_the_window_are_one_summary() -> void:
	var router := _router()
	_at(1000.0, MORNING)
	# Three DIFFERENT P2 problems, all inside the 15-minute window.
	router.feed({"type": &"water_main_break", "edge": "M-1", "severity": 0.5,
			"damage_fraction": 0.3})
	router.feed({"type": &"PowerComponentFailed", "component": "T-04", "cause": "age"})
	router.feed({"type": &"water_pump_tripped", "node": "P-02", "power_fraction": 0.1})
	assert_eq(router.pending_count(), 3)
	var decided := router.flush()
	assert_eq(decided.size(), 1, "three problems, one buzz")
	var summary: Dictionary = decided[0]
	assert_eq(str(summary["notify_id"]), "coalesced_summary")
	assert_eq(int(summary["count"]), 3)
	assert_eq(str(summary["deeplink"]), "report", "…tap to review")
	assert_true(bool(summary["allowed"]))
	# One token, not three — the doc's own phrasing, and the reason the feature
	# exists at all.
	assert_almost_eq(router.budget().tokens("P2_important"), 2.0, 0.001)
	assert_almost_eq(router.budget().global_tokens(), 7.0, 0.001)


func test_19_two_is_not_a_pile_and_the_summary_carries_the_worst_severity() -> void:
	var router := _router()
	_at(2000.0, MORNING)
	router.feed({"type": &"water_pump_tripped", "node": "P-02", "power_fraction": 0.1})
	router.feed({"type": &"PowerComponentTripped", "component": "F_SOUTH"})
	var decided := router.flush()
	assert_eq(decided.size(), 2, "two of a class stay two notifications")
	for plan: Dictionary in decided:
		assert_ne(str(plan["notify_id"]), "coalesced_summary")

	# A group carrying one severe member is summarised at THAT severity, so a
	# collapsed emergency does not quietly become routine.
	var severe := _router()
	_at(4000.0, MORNING)
	severe.feed({"type": &"water_main_break", "edge": "M-1", "severity": 0.5,
			"damage_fraction": 0.3})       # severity 3
	severe.feed({"type": &"PowerComponentTripped", "component": "F_A"})   # severity 2
	severe.feed({"type": &"PowerComponentTripped", "component": "F_B"})   # severity 2
	var summary: Dictionary = severe.flush()[0]
	assert_eq(str(summary["notify_id"]), "coalesced_summary")
	assert_eq(int(summary["severity"]), 3, "the group's worst, not its average")
	assert_eq((summary["coalesced"] as Array).size(), 3,
			"and it remembers what it swallowed")


func test_20_classes_coalesce_separately() -> void:
	var router := _router()
	_at(6000.0, MORNING)
	for i in 3:
		router.feed({"type": &"PowerComponentFailed", "component": "T-%02d" % i,
				"cause": "age"})                                   # P2 x3
	for i in 3:
		router.feed({"type": &"building_completed", "building": i, "level": 2})  # P3 x3
	var decided := router.flush()
	assert_eq(decided.size(), 2, "one summary per class, not one for everything")
	var classes: PackedStringArray = []
	for plan: Dictionary in decided:
		assert_eq(str(plan["notify_id"]), "coalesced_summary")
		classes.append(str(plan["class"]))
	classes.sort()
	assert_eq(classes, PackedStringArray(["P2_important", "P3_routine"]))


# ===========================================================================
# The router: denial is recorded, never dropped
# ===========================================================================

func test_21_a_refused_push_is_kept_with_its_reason() -> void:
	# doc 08 §2.13.2: on deny the event STILL enters the ring and STILL appears
	# in the report. Nothing is lost, only un-buzzed — so a refusal has to be a
	# recorded decision and not a silence.
	var router := _router()
	var suppressed: Array = []
	router.notification_suppressed.connect(func(key: String, reason: String) -> void:
		suppressed.append([key, reason]))
	_at(0.0, MORNING)
	router.feed({"type": &"credit_limit_reached", "balance": -5000000,
			"credit_limit": 5000000})
	router.flush()
	assert_eq(router.allowed_count(), 1)
	# A second P1 two minutes later: inside the global 5-minute gap.
	_at(2.0, MORNING)
	router.feed({"type": &"water_zone_offline", "zone": "Z1", "dead": true})
	var decided := router.flush()
	assert_eq(decided.size(), 1, "the decision was still MADE")
	assert_false(bool(decided[0]["allowed"]))
	assert_eq(str(decided[0]["reason"]), NotificationBudget.REASON_GLOBAL_GAP)
	assert_eq(suppressed.size(), 1, "and it was reported as suppressed, with a reason")
	assert_eq(str(suppressed[0][1]), NotificationBudget.REASON_GLOBAL_GAP)
	assert_eq(router.suppressed_count(), 1)
	assert_eq(router.plans().size(), 2, "both decisions are on the record")


func test_22_the_key_is_the_events_own_aggregation_rule() -> void:
	# `aggregate: true` events share ONE cooldown key — every dark block is one
	# outage — and the rest are per entity, so two transformers are two stories.
	var router := _router()
	_at(0.0, MORNING)
	var a := router.feed({"type": &"BlockDarkChanged", "block_id": "B1",
			"block_dark": true})
	var b := router.feed({"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true})
	assert_eq(str(a["key"]), str(b["key"]), "one outage, one key")
	assert_eq(str(a["key"]), "outage_major")

	var t1 := router.feed({"type": &"weather_warning", "event_uid": 1,
			"kind": "severe_thunderstorm", "impact_min": 40, "lead_min": 25})
	assert_eq(str(t1["key"]), "weather_warning", "a forecast is one story too")

	var i1 := router.feed({"type": &"incident_created", "incident_id": 7,
			"incident_type": "structure_fire", "tile": [1, 1], "severity": 0.9,
			"tier": 4, "notification_priority": 1})
	assert_eq(str(i1["key"]), "incident_started/7", "but an incident is its own")
	assert_eq(str(i1["deeplink"]), "incident/7", "and its deeplink names it")


func test_23_a_deeplink_that_cannot_be_filled_is_dropped_not_shown() -> void:
	# A tap that lands nowhere is worse than a notification you can only read.
	assert_eq(NotificationRouter._deeplink("incident/{ref}", 7), "incident/7")
	assert_eq(NotificationRouter._deeplink("incident/{ref}", null), "")
	assert_eq(NotificationRouter._deeplink("overlay/power", null), "overlay/power")
	assert_eq(NotificationRouter._deeplink("", 7), "")


func test_24_the_bindings_are_ordered_and_the_first_match_wins() -> void:
	var router := _router()
	var dark := router.rule_for({"type": &"BlockDarkChanged", "block_id": "B1",
			"block_dark": true})
	var lit := router.rule_for({"type": &"BlockDarkChanged", "block_id": "B1",
			"block_dark": false})
	assert_eq(str(dark["notify_id"]), "outage_major")
	assert_eq(str(lit["notify_id"]), "power_restored",
			"the `match` block picks between two rules on one event type")
	assert_true(router.rule_for({"type": &"congestion_updated", "edge_id": 1}).is_empty(),
			"and an event nobody bound makes no notification")
	assert_true(router.feed({"type": &"vehicle_state", "id": 3}).is_empty())


func test_25_buckets_survive_a_restart() -> void:
	# §2.13.2: persisted in the `notifications` save section, because a player
	# who closes the app must not get a fresh bucket by doing so.
	var router := _router()
	_at(0.0, MORNING)
	router.feed({"type": &"credit_limit_reached", "balance": -5000000})
	router.flush()
	var spent := router.budget().global_tokens()
	assert_almost_eq(spent, 7.0, 0.001)

	var saved := router.serialize()
	var reloaded := _router()
	assert_almost_eq(reloaded.budget().global_tokens(), 8.0, 0.001, "a fresh one is full")
	reloaded.deserialize(saved)
	assert_almost_eq(reloaded.budget().global_tokens(), spent, 0.001,
			"and a loaded one is exactly where the old one left off")
	assert_almost_eq(reloaded.budget().tokens("P1_critical"),
			router.budget().tokens("P1_critical"), 0.001)
	# The per-key cooldowns come back too, or a restart would be a way to buzz
	# about the same transformer twice.
	_at(1.0, MORNING)
	assert_eq(reloaded.budget().check("P1_critical", 4, "treasury_critical", 240.0,
			1.0, MORNING), NotificationBudget.REASON_GLOBAL_GAP)


# ===========================================================================
# The seam
# ===========================================================================

func test_26_the_default_sink_is_inert_and_the_router_does_not_care() -> void:
	var router := _router()
	assert_false(router.sink().is_available(),
			"nothing delivers a push in the slice — doc 13 phase 2 owns the platform")
	_at(0.0, MORNING)
	router.feed({"type": &"credit_limit_reached", "balance": -5000000})
	var plan: Dictionary = router.flush()[0]
	assert_true(bool(plan["allowed"]), "the DECISION is made and it is 'yes'")
	assert_false(bool(plan["delivered"]), "…and nothing delivered it, which is fine")
	assert_ne(str(plan["channel_id"]), "", "the plan names the channel it would use")
	assert_eq(str(plan["title_key"]), "n_treasury_critical_title",
			"and carries copy as KEYS, never sentences (G-8)")


func test_27_a_sink_that_can_deliver_gets_the_plan_unmodified() -> void:
	var sink := RecordingSink.new()
	var router := _router(sink)
	_at(0.0, MORNING)
	router.feed({"type": &"water_zone_offline", "zone": "Z1", "dead": true})
	var plan: Dictionary = router.flush()[0]
	assert_true(bool(plan["delivered"]))
	assert_eq(sink.plans.size(), 1)
	assert_eq(str((sink.plans[0] as Dictionary)["notify_id"]), "water_zone_offline")
	assert_eq(str((sink.plans[0] as Dictionary)["channel_id"]), "slacum_critical")
	# A refused plan never reaches the platform at all: doc 13 applies no rate
	# limiting of its own (C-71), so everything it is handed is final.
	_at(1.0, MORNING)
	router.feed({"type": &"water_zone_offline", "zone": "Z2", "dead": true})
	router.flush()
	assert_eq(sink.plans.size(), 1, "the suppressed one was never offered")


func test_28_swapping_a_sink_in_creates_the_channels() -> void:
	var sink := RecordingSink.new()
	var router := _router()
	router.set_sink(sink)
	# One per ENABLED class: P4 has no channel in MVP, because an empty channel
	# in Android settings is a promise the game does not keep.
	assert_eq(sink.channels, 3, "P1, P2, P3 — and not P4")
	assert_true(sink.channel_ids.has("slacum_critical"))
	assert_false(sink.channel_ids.has("slacum_ambient"))


func test_29_the_native_sink_is_finished_and_inert() -> void:
	# The seam's other half: complete, wired, and false on every build until the
	# Kotlin side gains `postNotification`. That is what makes doc 13 phase 2 a
	# Kotlin change rather than a refactor of everything above this line.
	var sink := NativeNotificationSink.new()
	assert_false(sink.is_available(),
			"SlacumNative ships elapsedRealtime/boot_id/thermal and no notifications")
	assert_eq(sink.ensure_channels([{"channel_id": "slacum_critical",
			"mvp_enabled": true}]), 0)
	assert_false(sink.deliver({"notify_id": "x"}))
	assert_eq(sink.cancel_all(), 0)
	# …but it still records what it was asked to do, so the pipeline is
	# observable on a device with no plugin at all.
	assert_eq(sink.log_entries().size(), 1)
	assert_eq(AndroidNative.detect().supports_notifications(), false)


func test_30_the_lifecycle_plans_on_pause_and_replans_on_resume() -> void:
	# doc 08 §2.13's two moments, and the only two places a notification's
	# TIMING is decided.
	var sink := RecordingSink.new()
	var router := _router(sink)
	var life := AndroidLifecycle.new()
	life.notification_router = router
	var wall := 1000.0
	life.wall_clock = func() -> float: return wall
	life.mono_clock = func() -> float: return wall

	_at(0.0, MORNING)
	router.feed({"type": &"credit_limit_reached", "balance": -5000000})
	assert_eq(router.pending_count(), 1, "queued, not yet decided")
	life._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_eq(router.pending_count(), 0, "the pause ran the scheduling pass")
	assert_eq(sink.plans.size(), 1)

	# Something queued while backgrounded, then a resume: pending alarms are
	# cancelled and the queue is dropped, because the catch-up about to run has
	# replaced the future they assumed.
	router.feed({"type": &"water_zone_offline", "zone": "Z9", "dead": true})
	assert_eq(router.pending_count(), 1)
	wall += 60.0
	life._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(sink.cancelled, 1, "every pending alarm was cancelled")
	assert_eq(router.pending_count(), 0, "and nothing stale survived the resume")
	life.free()


## A sink that can deliver, for the tests that need one. Doc 13 phase 2's real
## one is this shape with Kotlin behind it.
class RecordingSink extends NotificationSink:
	var plans: Array[Dictionary] = []
	var channel_ids: PackedStringArray = []
	var channels := 0
	var cancelled := 0

	func is_available() -> bool:
		return true

	func ensure_channels(class_rows: Array) -> int:
		channels = 0
		channel_ids = PackedStringArray()
		for raw: Variant in class_rows:
			var row: Dictionary = raw
			if not bool(row.get("mvp_enabled", true)):
				continue
			channel_ids.append(str(row.get("channel_id", "")))
			channels += 1
		return channels

	func deliver(plan: Dictionary) -> bool:
		plans.append(plan)
		return true

	func cancel_all() -> int:
		cancelled += 1
		return cancelled
