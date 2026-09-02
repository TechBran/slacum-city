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


# ===========================================================================
# PA-31 — the wear says what it costs
# ===========================================================================

## A building driven straight to `value` without touching the clock, so a band
## test measures the crossing rule and not a decay rate.
func _set_condition(sim: CitySim, sim_id: String, value: float) -> Building:
	var b: Building = sim.buildings[sim_id]
	b.condition = value
	return b


func _first_private(sim: CitySim) -> String:
	for id: String in sim.roster_ids():
		if (sim.buildings[id] as Building).owner_maintained:
			return String(id)
	return ""


func _first_city_owned(sim: CitySim) -> String:
	for id: String in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if not b.owner_maintained and b.decays():
			return String(id)
	return ""


func test_pa31_a_downward_crossing_of_each_band_is_one_event() -> void:
	var sim := _sim()
	var sim_id := _first_city_owned(sim)
	assert_ne(sim_id, "", "the starter city owns buildings")
	var b: Building = sim.buildings[sim_id]
	var seen: Array = []
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == &"building_condition_band" \
				and str(event.get("sim_id", "")) == sim_id:
			seen.append(event.duplicate())

	# Good → Worn: one event, naming the band it left.
	b.condition = b.rule("band_good") + 0.01
	sim._emit_condition_band(sim_id, b, 1.0)
	assert_eq(seen.size(), 0, "still in Good — no crossing")
	b.condition = b.rule("band_good") - 0.01
	sim._emit_condition_band(sim_id, b, b.rule("band_good") + 0.01)
	assert_eq(seen.size(), 1, "Good → Worn is one event")
	assert_eq(str((seen[0] as Dictionary)["band"]), "worn")
	assert_eq(str((seen[0] as Dictionary)["previous"]), "")

	# Another hour of wear inside the SAME band says nothing.
	sim._emit_condition_band(sim_id, b, b.rule("band_good") - 0.005)
	assert_eq(seen.size(), 1, "a band the player already knows about is silent")

	# Worn → Poor.
	var was := b.condition
	b.condition = b.rule("band_worn") - 0.01
	sim._emit_condition_band(sim_id, b, was)
	assert_eq(seen.size(), 2, "Worn → Poor is the second event")
	assert_eq(str((seen[1] as Dictionary)["band"]), "poor")
	assert_eq(str((seen[1] as Dictionary)["previous"]), "worn")
	sim.bus.observer = Callable()


func test_pa31_climbing_back_out_of_a_band_says_nothing() -> void:
	# A building coming back up is the player's own repair or upgrade finishing,
	# and the screen that issued it already knows (doc 93's `player_initiated`).
	var sim := _sim()
	var sim_id := _first_city_owned(sim)
	var b: Building = sim.buildings[sim_id]
	var seen := 0
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == &"building_condition_band":
			seen += 1
	b.condition = b.rule("band_worn") + 0.05          # Poor → Worn
	sim._emit_condition_band(sim_id, b, b.rule("band_worn") - 0.05)
	assert_eq(seen, 0, "Poor → Worn is a recovery")
	b.condition = 1.0                                  # Worn → Good
	sim._emit_condition_band(sim_id, b, b.rule("band_good") - 0.05)
	assert_eq(seen, 0, "Worn → Good is a recovery")
	sim.bus.observer = Callable()


func test_pa31_private_stock_reaches_worn_and_the_event_is_the_only_cue() -> void:
	# The sharp edge doc 93 §Y1 created: an owner holds their building at
	# `band_worn`, so it can NEVER reach `damaged` and `building_damaged` — the
	# one condition cue the game used to have — is unreachable for the four
	# revenue classes. This event has to be the cue, and it has to say the
	# building is private so a surface never offers a repair that does not exist.
	var sim := _sim()
	var sim_id := _first_private(sim)
	assert_ne(sim_id, "", "the starter city has private stock")
	var b: Building = sim.buildings[sim_id]
	var seen: Array = []
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == &"building_condition_band" \
				and str(event.get("sim_id", "")) == sim_id:
			seen.append(event.duplicate())
	b.condition = b.rule("band_good") - 0.01
	sim._emit_condition_band(sim_id, b, 1.0)
	sim.bus.observer = Callable()
	assert_eq(seen.size(), 1)
	assert_true(bool((seen[0] as Dictionary)["owner_maintained"]),
			"the payload says the city cannot buy this repair")
	assert_eq(str(sim.cmd_repair_building(sim_id)["reason_code"]), "E_OWNER_MAINTAINED",
			"and the command agrees")


func test_pa31_the_band_thresholds_are_doc_02s_own_table() -> void:
	# No second copy: perturb the stamped rule and the band moves with it.
	var sim := _sim()
	var sim_id := _first_city_owned(sim)
	var b: Building = sim.buildings[sim_id]
	assert_eq(String(CitySim._condition_band_of(b, b.rule("band_good"))), "",
			"exactly at band_good is still Good")
	assert_eq(String(CitySim._condition_band_of(b, b.rule("band_good") - 0.001)), "worn")
	assert_eq(String(CitySim._condition_band_of(b, b.rule("band_worn"))), "worn",
			"exactly at band_worn is still Worn — the ownership floor sits here")
	assert_eq(String(CitySim._condition_band_of(b, b.rule("band_worn") - 0.001)), "poor")
	b.condition_rules = b.condition_rules.duplicate()
	b.condition_rules["band_good"] = 0.50
	assert_eq(String(CitySim._condition_band_of(b, 0.60)), "",
			"the band follows the authored key, it does not restate it")


func test_pa31_both_bands_reach_a_surface() -> void:
	var cfg := _cfg()
	var wanted := {"worn": "buildings_worn", "poor": "buildings_poor"}
	var log_rows: Dictionary = {}
	for raw: Variant in (cfg.section("event_log").get("events", []) as Array):
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != "building_condition_band":
			continue
		var band := str((rule.get("match", {}) as Dictionary).get("band", ""))
		assert_true(wanted.has(band), "each rule matches one authored band")
		log_rows[band] = str(rule["notify_id"])
		assert_eq(str(rule.get("key", "")), "building",
				"keyed on the building, so a row can carry `Jump to it`")
	for band: String in wanted:
		assert_eq(str(log_rows.get(band, "")), str(wanted[band]),
				"%s has a log row" % band)

	var notify := NotificationConfig.load_from_files()
	var classes: Dictionary = {}
	for raw2: Variant in notify.bindings():
		var binding: Dictionary = raw2
		if str(binding.get("type", "")) != "building_condition_band":
			continue
		var notify_id := str(binding["notify_id"])
		classes[notify_id] = str(notify.event_def(notify_id).get("class", ""))
	assert_eq(classes.size(), 2, "both bands are offered to doc 08")
	for notify_id: String in classes:
		assert_eq(str(classes[notify_id]), "P3_routine",
				"%s is routine — a worn city is a slow bill, not an emergency"
						% notify_id)
		assert_true(bool(notify.event_def(notify_id).get("aggregate", false)),
				"%s aggregates: one line that says how many" % notify_id)


# ===========================================================================
# PA-33 — the city repairs what it owns
# ===========================================================================

## Wear every city-owned building down to `value` and return how many there are.
func _wear_city_stock(sim: CitySim, value: float) -> int:
	var n := 0
	for id: String in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained or b.state != &"active":
			continue
		b.condition = value
		n += 1
	return n


func test_pa33_the_shipped_default_is_manual_and_writes_nothing() -> void:
	# RR-150's whole second half. A city that never opens the control must be
	# byte-identical to the Wave-17 fork, which means the pair is not in the save
	# at all — an unconditional key would move all four profile_sim baselines for
	# a feature that, at its default, does nothing.
	var sim := _sim()
	assert_almost_eq(sim.building_repair_threshold, 0.0, 1e-9, "off by default")
	assert_eq(sim.building_repair_daily_cap, 0, "no budget by default")
	assert_false(bool(sim.building_repair_policy()["enabled"]))
	var policy: Dictionary = sim.capture_state()["policy"]
	assert_false(policy.has("building_repair"),
			"the city section carries no key until the player moves the dial")

	# And with the policy on, it IS written, and it round-trips.
	assert_true(bool(sim.cmd_set_building_repair_policy(
			sim.building_repair_thresholds()[1], 12345)["ok"]))
	var written: Dictionary = sim.capture_state()["policy"]
	assert_true(written.has("building_repair"), "a moved dial is saved")
	var restored := _sim()
	restored.restore_state(sim.capture_state())
	assert_almost_eq(restored.building_repair_threshold,
			sim.building_repair_threshold, 1e-9)
	assert_eq(restored.building_repair_daily_cap, 12345)


func test_pa33_the_threshold_ladder_is_doc_02s_band_table() -> void:
	var sim := _sim()
	var ladder := sim.building_repair_thresholds()
	assert_eq(ladder.size(), 3, "off, Worn, Good")
	assert_almost_eq(ladder[0], 0.0, 1e-9, "rung 0 is off")
	var sample: Building = sim.buildings[_first_city_owned(sim)]
	assert_almost_eq(ladder[1], sample.rule("band_worn"), 1e-9,
			"rung 1 is doc 02's band_worn, not a copy of it")
	assert_almost_eq(ladder[2], sample.rule("band_good"), 1e-9,
			"rung 2 is doc 02's band_good, not a copy of it")
	# A rung the command would refuse can therefore never reach a control.
	var refused: Dictionary = sim.cmd_set_building_repair_policy(0.73, 10000)
	assert_false(bool(refused["ok"]))
	assert_eq(str(refused["reason_code"]), "E_BAD_THRESHOLD")
	assert_eq((refused["payload"] as Dictionary)["allowed"], ladder,
			"the refusal hands back the ladder the control should be drawn from")
	assert_almost_eq(sim.building_repair_threshold, 0.0, 1e-9,
			"a refused move changed nothing")


func test_pa33_repair_all_worn_never_offers_a_repair_the_city_cannot_buy() -> void:
	var sim := _sim()
	# Wear EVERYTHING, private stock included.
	for id: String in sim.roster_ids():
		(sim.buildings[id] as Building).condition = 0.50
	var quote: Dictionary = sim.cmd_repair_all_worn(true)
	assert_true(bool(quote["ok"]))
	var payload: Dictionary = quote["payload"]
	assert_true(int(payload["count"]) > 0, "there is work to buy")
	for raw: Variant in (payload["sim_ids"] as Array):
		var b: Building = sim.buildings[str(raw)]
		assert_false(b.owner_maintained,
				"%s is private — E_OWNER_MAINTAINED, so the batch never offers it"
						% str(raw))
	# And the quote is doc 03's, not a second sum: it equals the sum of the same
	# previews the building panel's REPAIR button takes.
	var by_hand := 0
	for raw2: Variant in (payload["sim_ids"] as Array):
		by_hand += int((sim.cmd_repair_building(str(raw2), true)["payload"]
				as Dictionary)["cost"])
	assert_eq(int(payload["cost"]), by_hand,
			"the batch price is the sum of doc 03's own quotes")


func test_pa33_a_preview_buys_nothing_and_the_commit_buys_what_it_quoted() -> void:
	var sim := _sim()
	_wear_city_stock(sim, 0.50)
	var before := sim.treasury.balance
	var quote: Dictionary = sim.cmd_repair_all_worn(true)["payload"]
	assert_almost_eq(sim.treasury.balance, before, 1e-6, "a preview is free")
	var done: Dictionary = sim.cmd_repair_all_worn(false)["payload"]
	assert_eq(int(done["count"]), int(quote["count"]),
			"the button's face and the button's effect are the same pass")
	assert_almost_eq(sim.treasury.balance, before - float(done["cost"]), 1.0,
			"the treasury moved by exactly what was quoted")


func test_pa33_the_daily_cap_is_a_budget_and_it_is_respected() -> void:
	var sim := _sim()
	_wear_city_stock(sim, 0.40)
	var full: Dictionary = sim.cmd_repair_all_worn(true)["payload"]
	assert_true(int(full["count"]) >= 2, "enough candidates to cap")
	var cap := int(full["cost"]) / 2
	var capped: Dictionary = sim.cmd_repair_all_worn(true, -1.0, cap)["payload"]
	assert_true(int(capped["cost"]) <= cap, "the pass stops at the budget")
	assert_true(int(capped["count"]) < int(full["count"]),
			"and it does less work than the uncapped pass")
	assert_true(int(capped["skipped"]) > 0,
			"the surface can say `N of M`, not quietly do less than it offered")


func test_pa33_the_pass_is_worst_first_and_deterministic() -> void:
	var sim := _sim()
	var ids: Array[String] = []
	for id: String in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if not b.owner_maintained and b.state == &"active":
			ids.append(String(id))
	assert_true(ids.size() >= 3, "enough city stock to order")
	# Descending condition down the roster, so worst-first is NOT roster order.
	for index in ids.size():
		(sim.buildings[ids[index]] as Building).condition = 0.80 - 0.05 * float(index)
	var pass_a: Array = (sim.cmd_repair_all_worn(true)["payload"] as Dictionary)["sim_ids"]
	var pass_b: Array = (sim.cmd_repair_all_worn(true)["payload"] as Dictionary)["sim_ids"]
	assert_eq(pass_a, pass_b, "two previews of one city queue the same order")
	assert_eq(str(pass_a[0]), ids[ids.size() - 1],
			"the worst building is bought first — a fixed budget buys the repairs "
			+ "that are costing the city the most")


func test_pa33_the_policy_runs_once_a_game_day_and_reports_what_it_spent() -> void:
	var sim := _sim()
	assert_true(bool(sim.cmd_set_building_repair_policy(
			sim.building_repair_thresholds()[2], 1000000)["ok"]))
	_wear_city_stock(sim, 0.50)
	var runs: Array = []
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == &"building_repair_policy_ran":
			runs.append(event.duplicate())
	var before := sim.treasury.balance
	sim.advance_coarse_hours(HOURS_PER_DAY)
	sim.bus.observer = Callable()
	assert_eq(runs.size(), 1, "one pass per game-day, on the boundary")
	var run: Dictionary = runs[0]
	assert_true(int(run["count"]) > 0, "it repaired something")
	assert_true(int(run["cost"]) > 0, "and it says what that cost")
	assert_true(sim.treasury.balance < before,
			"the money left the treasury, which is why the receipt exists")


func test_pa33_a_manual_city_never_runs_the_pass() -> void:
	var sim := _sim()
	_wear_city_stock(sim, 0.30)
	var runs := 0
	sim.bus.observer = func(event: Dictionary) -> void:
		if StringName(String(event.get("type", &""))) == &"building_repair_policy_ran":
			runs += 1
	sim.advance_coarse_hours(HOURS_PER_DAY * 3)
	sim.bus.observer = Callable()
	assert_eq(runs, 0, "the shipped default takes no quote and moves no dollar")


func test_pa33_the_receipt_reaches_a_surface() -> void:
	var cfg := _cfg()
	var log_rows := 0
	for raw: Variant in (cfg.section("event_log").get("events", []) as Array):
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != "building_repair_policy_ran":
			continue
		log_rows += 1
		var args: Dictionary = rule["args"]
		assert_eq(str(args["count"]), "count",
				"the row prints the pass's OWN count, not the log's @count of 1")
	assert_eq(log_rows, 1)
	var notify := NotificationConfig.load_from_files()
	var bound := 0
	for raw2: Variant in notify.bindings():
		if str((raw2 as Dictionary).get("type", "")) == "building_repair_policy_ran":
			bound += 1
	assert_eq(bound, 1, "a policy that spends the player's money says so")


# ===========================================================================
# The Upkeep band — PA-31's target, drawn: the lost $/gh and the repair total
# on ONE screen
# ===========================================================================

func test_upkeep_the_loss_is_doc_03s_own_rows_read_back() -> void:
	# `(1 − f_condition) × tax`, where tax is what the row would pay at 1.00.
	# Two rows: one at f_condition 0.80 earning 800 (so 1000 at full, 200 lost),
	# one untouched at 1.00 earning 500.
	var model := BudgetModel.load_from_files()
	model.feed_settlement({
		"hour": 100,
		"revenue": {"tax": 1300.0, "gross": 1300.0},
		"expenses": {"total": 400.0},
		"net": 900.0,
		"buildings": [
			{"f_condition": 0.80, "revenue": 800.0},
			{"f_condition": 1.00, "revenue": 500.0},
		],
	})
	var loss := model.condition_loss()
	assert_true(bool(loss["has_data"]))
	assert_almost_eq(float(loss["tax_lost_per_hour"]), 200.0, 1e-6,
			"800/0.80 − 800 = 200")
	assert_almost_eq(float(loss["tax_at_full"]), 1500.0, 1e-6)
	assert_eq(int(loss["worn"]), 1, "one row is paying less than full")
	assert_eq(int(loss["counted"]), 2)
	assert_almost_eq(float(loss["f_condition_mean"]), 0.90, 1e-6)


func test_upkeep_a_settlement_with_no_rows_says_so_rather_than_zero() -> void:
	var model := BudgetModel.load_from_files()
	model.feed_settlement({"hour": 4, "gross": 10.0, "expense": 2.0, "net": 8.0})
	var loss := model.condition_loss()
	assert_false(bool(loss["has_data"]),
			"the bus event carries no per-building rows, and a band that "
			+ "printed $0 from that would be lying about a city it cannot see")


func test_upkeep_the_band_prints_the_loss_and_the_price_of_ending_it() -> void:
	var model := DashboardModel.load_from_files()
	model.budget.feed_settlement({
		"hour": 100,
		"revenue": {"tax": 800.0, "gross": 800.0},
		"expenses": {"total": 100.0}, "net": 700.0,
		"buildings": [{"f_condition": 0.80, "revenue": 800.0}],
	})
	model.feed_upkeep({
		"quote": {"count": 7, "cost": 18900, "candidates": 9, "skipped": 2},
		"policy": {"building_repair_threshold": 0.0, "building_repair_daily_cap": 0,
				"enabled": false},
		"balance": 250000.0,
	})
	var band := model.upkeep_view()
	assert_true(bool(band["has_data"]))
	assert_almost_eq(float(band["tax_lost_per_hour"]), 200.0, 1e-6)
	assert_true(str(band["loss_text"]).contains("200"),
			"the loss is on the band as money: " + str(band["loss_text"]))
	assert_eq(str(band["loss_state"]), str(HudModel.STATE_WARNING))
	assert_true(str(band["repair_text"]).contains("7"), "the count is on the button")
	assert_true(str(band["repair_text"]).contains("18,900"),
			"and so is the price: " + str(band["repair_text"]))
	assert_true(bool(band["can_repair"]), "the treasury covers it")
	assert_eq(str(band["policy_text"]),
			UIWidgets.t(_cfg(), "ui_dashboard_upkeep_policy_off"),
			"and the standing policy is stated, off included")


func test_upkeep_an_unaffordable_batch_shows_its_price_on_a_dead_face() -> void:
	var model := DashboardModel.load_from_files()
	model.feed_upkeep({
		"quote": {"count": 4, "cost": 90000},
		"policy": {"enabled": false},
		"balance": 1200.0,
	})
	var band := model.upkeep_view()
	assert_true(bool(band["has_repair"]), "the work exists")
	assert_false(bool(band["can_repair"]), "the money does not")
	assert_true(bool(band["unaffordable"]))
	assert_true(str(band["repair_text"]).contains("90,000"),
			"the price is still shown, which is the whole point of a dead face")


func test_upkeep_nothing_to_repair_is_words_not_a_dead_button() -> void:
	var model := DashboardModel.load_from_files()
	model.feed_upkeep({"quote": {"count": 0, "cost": 0}, "policy": {"enabled": false},
			"balance": 50000.0})
	var band := model.upkeep_view()
	assert_false(bool(band["has_repair"]))
	assert_ne(str(band["none_text"]), "", "A14: it says so in words")


func test_upkeep_a_live_policy_states_its_two_dials() -> void:
	var model := DashboardModel.load_from_files()
	model.feed_upkeep({
		"quote": {"count": 1, "cost": 100},
		"policy": {"building_repair_threshold": 0.85,
				"building_repair_daily_cap": 10000, "enabled": true},
		"balance": 50000.0,
	})
	var text := str(model.upkeep_view()["policy_text"])
	assert_true(text.contains("85"), "the threshold is stated: " + text)
	assert_true(text.contains("10,000"), "and the budget is: " + text)


func test_upkeep_the_band_is_the_real_sim_end_to_end() -> void:
	# The JOIN this row is actually about: a real worn city, doc 03's real
	# settlement, and `cmd_repair_all_worn`'s real quote, all reaching one band.
	var sim := _sim()
	_wear_city_stock(sim, 0.55)
	for id: String in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.owner_maintained:
			b.condition = 0.70
	sim.advance_coarse_hours(1)
	var model := DashboardModel.load_from_files()
	model.budget.feed_settlement(sim.last_settlement)
	var quote: Dictionary = sim.cmd_repair_all_worn(true)["payload"]
	model.feed_upkeep({"quote": quote, "policy": sim.building_repair_policy(),
			"balance": float(sim.treasury.balance)})
	var band := model.upkeep_view()
	assert_true(float(band["tax_lost_per_hour"]) > 0.0,
			"a worn city is losing tax, and the band says how much")
	assert_true(int(band["worn"]) > 0, "and how much of the stock is below Good")
	assert_true(int(band["repair_count"]) > 0,
			"and what the city can buy to stop it")
	assert_true(int(band["repair_cost"]) > 0)
	# The two counts are deliberately different sets, and the band never conflates
	# them: private stock is in the loss and can never be in the quote.
	assert_true(int(band["worn"]) >= int(band["repair_count"]),
			"the loss counts taxed stock; the button counts what the city owns")
