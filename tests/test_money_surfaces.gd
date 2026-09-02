extends SimTest
## **Money has surfaces** — the gates for 99-PA's Lane S rows (Wave 18).
##
## The audit's finding across all four rows is one finding: the simulation knows
## what the money is doing and no screen says so. Each row here is therefore a
## JOIN test — a real `CitySim`, a real settlement, and an assertion that the
## number the sim computed reaches the table, the model or the command that a
## player can actually see or press.
##
##   * **PA-32** (doc 98 RR-148) — doc 03 §2.5a's founding assistance tapers
##     $589.71 a game-day for seven game-days. It now says so: `assistance_stepped`
##     once per game-day, eight per city, the last one flagged `final`; the
##     Economy tab's assistance row carries the per-day rate and the end day.
##   * **PA-31** surface half (doc 98 RR-149) — `building_condition_band` on a
##     downward crossing of doc 02 §2.6's `band_good` / `band_worn`, and an
##     Upkeep band on the Economy tab that puts the tax the city is losing to
##     condition and the repair quote to end it on one screen.
##   * **PA-33** (doc 98 RR-150) — `cmd_set_building_repair_policy` and
##     `cmd_repair_all_worn`: the city repairs what it owns under a policy, the
##     way roads already do, and the default is MANUAL so the balance matrix does
##     not move.
##   * **PA-83** — `development_phase_charged` reaches a log row.


const HOURS_PER_DAY := 24
## Doc 03 §2.5a, as `data/economy.json` authors it. Read, never restated: the
## assertions below compare against the file.
const ASSISTANCE_KEY := "FOUNDING_ASSISTANCE_DAYS"


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _sim() -> CitySim:
	return CitySim.boot_from_files()


## Every event of one type a run emitted, in order.
func _collect(sim: CitySim, wanted: StringName, hours: int) -> Array:
	var out: Array = []
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == wanted:
			out.append(event.duplicate())
	sim.advance_coarse_hours(hours)
	sim.bus.observer = Callable()
	return out


# ===========================================================================
# PA-32 — the founding grant tapers out loud
# ===========================================================================

func test_pa32_the_taper_steps_once_a_game_day_and_says_when_it_ends() -> void:
	var sim := _sim()
	var days := int(sim.econ_curves.grants().get(ASSISTANCE_KEY, 0))
	assert_true(days > 0, "doc 03 §2.5a authors a taper window")
	var steps := _collect(sim, &"assistance_stepped", HOURS_PER_DAY * (days + 2))

	# One per game-day of the window, plus the day it retires. Nothing after.
	assert_eq(steps.size(), days + 1,
			"%d steps + the final one, and then silence" % days)
	var final_count := 0
	for raw: Variant in steps:
		var step: Dictionary = raw
		var day := int(step["day"])
		assert_eq(int(step["hour"]), day * HOURS_PER_DAY,
				"a step lands on the game-day boundary, not inside one")
		assert_eq(int(step["end_day"]), int(step["day"]) + int(step["days_left"]),
				"end_day is the day the player can read off the row")
		assert_eq(int(step["end_day"]), days,
				"every step names the SAME end day — the window is published")
		if bool(step["final"]):
			final_count += 1
			assert_eq(int(step["days_left"]), 0, "the last step has nothing left")
			assert_almost_eq(float(step["per_day"]), 0.0, 1e-6,
					"the last step pays nothing — that is what makes it the last")
	assert_eq(final_count, 1, "exactly one toast-worthy step per city")


func test_pa32_each_step_is_the_published_daily_retirement() -> void:
	# Doc 03 §2.5a retires `FOUNDING_ASSISTANCE_PER_HOUR / DAYS` every game-day.
	# The event's `per_day` is that, ×24, and it is measured off the events rather
	# than restated here.
	var sim := _sim()
	var days := int(sim.econ_curves.grants().get(ASSISTANCE_KEY, 0))
	var steps := _collect(sim, &"assistance_stepped", HOURS_PER_DAY * (days + 1))
	assert_true(steps.size() >= 3, "enough steps to measure a slope")
	var first := float((steps[0] as Dictionary)["per_day"])
	var step_down := first / float(days)
	for index in range(1, steps.size()):
		var got := float((steps[index] as Dictionary)["per_day"])
		assert_almost_eq(got, first - step_down * float(index), 0.01,
				"step %d is one published rung below the founding day" % index)


func test_pa32_the_economy_row_carries_the_rate_and_the_end_day() -> void:
	# The audit's target: "the end day readable at any time". The row is built
	# from a settle snapshot verbatim, so a sheet that is open on game-day 3 says
	# what game-day 3's grant pays and which day it stops.
	var model := BudgetModel.load_from_files()
	model.feed_settlement({
		"hour": 3 * HOURS_PER_DAY,
		"assistance_days_left": 4,
		"revenue": {"tax": 900.0, "assistance": 98.29, "gross": 998.29},
		"expenses": {"departments": 96.0, "total": 96.0},
		"net": 902.29,
	})
	var rows: Array = model.breakdown()["revenue"]
	var assistance: Dictionary = {}
	for raw: Variant in rows:
		var row: Dictionary = raw
		if str(row["key"]) == "assistance":
			assistance = row
	assert_false(assistance.is_empty(), "the assistance line is drawn")
	assert_eq(int(assistance["days_left"]), 4)
	assert_eq(int(assistance["end_day"]), 7, "settled day 3 + 4 left = day 7")
	var note := str(assistance.get("note", ""))
	assert_true(note.contains("7"), "the note names the end day: " + note)
	assert_true(note.contains("4"), "the note names the days left: " + note)
	assert_true(note.contains(str(assistance["per_day_text"])),
			"the note quotes the row's own per-day rate: " + note)


func test_pa32_a_retired_taper_leaves_no_note_and_no_row() -> void:
	var model := BudgetModel.load_from_files()
	model.feed_settlement({
		"hour": 400, "assistance_days_left": 0,
		"revenue": {"tax": 900.0, "assistance": 0.0, "gross": 900.0},
		"expenses": {"departments": 96.0, "total": 96.0},
		"net": 804.0,
	})
	for raw: Variant in (model.breakdown()["revenue"] as Array):
		var row: Dictionary = raw
		assert_ne(str(row["key"]), "assistance",
				"a $0 grant is not a row that says $0")


func test_pa32_both_steps_reach_a_surface() -> void:
	# The router half: the routine step is a doc 12 log row and NOT a push (a
	# push a day for a week about a published schedule is the budget spent on
	# nothing the player can act on); the final step is both.
	var cfg := _cfg()
	var routine := 0
	var ended := 0
	for raw: Variant in (cfg.section("event_log").get("events", []) as Array):
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != "assistance_stepped":
			continue
		var wants_final := bool((rule.get("match", {}) as Dictionary).get("final", false))
		if wants_final:
			ended += 1
			assert_eq(str(rule["notify_id"]), "assistance_ended")
		else:
			routine += 1
			assert_eq(str(rule["notify_id"]), "assistance_stepped")
			var args: Dictionary = rule["args"]
			for name: String in ["days", "per_day", "end_day"]:
				assert_true(args.has(name),
						"the routine row supplies {%s}" % name)
	assert_eq(routine, 1, "one routine log rule")
	assert_eq(ended, 1, "one final log rule")

	var notify := NotificationConfig.load_from_files()
	var pushes := 0
	for raw2: Variant in notify.bindings():
		var binding: Dictionary = raw2
		if str(binding.get("type", "")) != "assistance_stepped":
			continue
		pushes += 1
		assert_eq(str(binding["notify_id"]), "assistance_ended",
				"only the LAST step is offered to doc 08")
		assert_true(bool((binding.get("match", {}) as Dictionary).get("final", false)),
				"and it is gated on `final`")
	assert_eq(pushes, 1, "one notification binding, for one moment per city")
