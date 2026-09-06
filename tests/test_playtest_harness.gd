extends SimTest
## The balance harness is a measuring instrument (doc 93 §E), so it gets the
## same treatment as a sim system: it must be deterministic, its strategies must
## actually play, and the JSON it writes must keep its shape — doc 92's tables
## and every future regression diff are read off that schema.
##
## Everything here runs on the COARSE (offline catch-up) path over 1–2 game-days
## so the suite stays fast; `tools/playtest.gd` defaults to the fine path for
## real reports.

const Playtest := preload("res://tools/playtest.gd")
## The gate rig, for the two Wave-15 fine-path tests below. It drives the same
## strategies and the same summariser this file's own `_run` does; what it adds
## is the FINE loop, which is the only path doc 06 §2.16's spawner draws on.
const Rig := preload("res://tests/balance_gate_rig.gd")

const TEST_OUT_DIR := "user://playtest_schema_test"

## Top-level keys every consumer of a run file is allowed to depend on.
const DOC_KEYS: Array[String] = [
	"schema_version", "harness", "run", "verbs", "samples", "actions",
	"events", "summary", "state_hash", "digest",
]
const SAMPLE_KEYS: Array[String] = [
	"h", "day", "hour_of_day", "treasury", "net", "revenue", "expenses",
	"population", "happiness", "stability", "city_level", "blackout_minutes",
	"buildings", "metered_buildings", "dark_buildings", "under_construction",
	"deferred_liability",
	# pass 2
	"damaged_buildings", "destroyed_buildings", "min_condition", "mean_condition",
	"open_incidents", "failed_components", "tax_rate", "blocks_owned",
]
const SUMMARY_KEYS: Array[String] = [
	"days", "hours", "treasury_start", "treasury_end", "treasury_min",
	"treasury_max", "net_first_hour", "net_last_hour", "net_mean_per_hour",
	"population_start", "population_end", "population_peak", "happiness_end",
	"happiness_min", "stability_end", "stability_min", "city_level_end",
	"blackout_minutes_total", "unserved_share", "dark_buildings_end",
	"buildings_start", "buildings_end", "placed", "upgraded",
	"construction_spend", "actions", "reason_codes", "deferred_liability_end",
	"austerity_active_end", "credit_limit_end", "lifetime", "day_rows",
	# pass 2
	"value_created", "grid_placed", "grid_spend", "repaired", "repair_spend",
	"demolished", "demolition_refund", "blocks_bought", "land_spend",
	"tax_changes", "priority_sets", "unserved_walls", "tax_rate_end",
	"tax_level_end", "blocks_owned_end", "min_condition", "min_condition_end",
	"mean_condition_end", "damaged_end", "destroyed_end",
	"failed_components_end", "open_incidents_mean",
	# Wave 15 — doc 06 §2.16's tap on an arc (RR-86).
	"opportunities_collected", "street_income", "street_missed",
	"street_share_of_net", "street_by_level",
]


static func _opts(days: int, strategy: String) -> Variant:
	var opts := Playtest.Options.new()
	opts.days = days
	opts.mode = "coarse"
	opts.strategies = [strategy] as Array[String]
	opts.write_json = false
	return opts


static func _run(strategy: String, seed_value: int, days: int = 2) -> Dictionary:
	return Playtest.Runner.run_one(strategy, seed_value, _opts(days, strategy))


# --------------------------------------------------------------- determinism

func test_same_seed_and_strategy_replays_identically() -> void:
	# The harness itself must add no entropy: sorted iteration everywhere, no
	# RNG of its own. Two runs of the same (strategy, seed, mode, days) are
	# byte-identical in the sample stream AND in the sim's own state hash.
	var a := _run("greedy_growth", 1337)
	var b := _run("greedy_growth", 1337)
	assert_eq(String(a["digest"]), String(b["digest"]), "sample digest")
	assert_eq(String(a["state_hash"]), String(b["state_hash"]), "sim state hash")
	assert_eq(JSON.stringify(a["samples"], "", true, true),
			JSON.stringify(b["samples"], "", true, true), "full sample stream")
	assert_eq(JSON.stringify(a["actions"], "", true, true),
			JSON.stringify(b["actions"], "", true, true), "action log")


func test_do_nothing_is_deterministic_and_silent() -> void:
	var a := _run("do_nothing", 4242)
	var b := _run("do_nothing", 4242)
	assert_eq(String(a["digest"]), String(b["digest"]))
	assert_eq((a["actions"] as Array).size(), 0, "do_nothing issues no commands")
	var summary: Dictionary = a["summary"]
	assert_eq(int(summary["placed"]), 0)
	assert_eq(int(summary["upgraded"]), 0)
	assert_eq(int(summary["buildings_end"]), int(summary["buildings_start"]),
			"the control run must not change the city's shape")


func test_a_different_strategy_diverges_from_the_control() -> void:
	var control := _run("do_nothing", 1337)
	var greedy := _run("greedy_growth", 1337)
	assert_ne(String(control["digest"]), String(greedy["digest"]),
			"playing the game must move the numbers")
	assert_ne(String(control["state_hash"]), String(greedy["state_hash"]))


# ----------------------------------------------------------------- behaviour

func test_greedy_places_a_building_before_day_two() -> void:
	# The audit's acceptance line for the harness: a greedy agent must actually
	# spend the founding $25,000 inside the first game-day, or the harness is
	# measuring a player who never plays.
	var report := _run("greedy_growth", 1337)
	var first_place_hour := -1
	for entry_variant in report["actions"]:
		var entry: Dictionary = entry_variant
		if String(entry["verb"]) == "place" and bool(entry["ok"]):
			first_place_hour = int(entry["hour"])
			break
	assert_true(first_place_hour >= 0, "greedy placed at least one building")
	assert_true(first_place_hour < 24,
			"first placement lands on game-day 1 (got hour %d)" % first_place_hour)
	var summary: Dictionary = report["summary"]
	assert_true(int(summary["placed"]) >= 1)
	assert_true(int(summary["buildings_end"]) > int(summary["buildings_start"]),
			"the city grew")
	assert_true(int(summary["construction_spend"]) > 0, "and it cost money")


func test_greedy_spends_down_and_balanced_does_not() -> void:
	# The two agents must be distinguishable on the axis they differ on:
	# greedy holds no reserve, balanced holds one.
	var greedy: Dictionary = _run("greedy_growth", 1337)["summary"]
	var balanced: Dictionary = _run("balanced", 1337)["summary"]
	assert_true(int(greedy["treasury_min"]) < int(balanced["treasury_min"]),
			"greedy bottoms out lower ($%d vs $%d)"
					% [int(greedy["treasury_min"]), int(balanced["treasury_min"])])
	assert_true(int(balanced["treasury_min"]) >= 0,
			"balanced never touches the credit line in a quiet fortnight")
	assert_true(int(greedy["construction_spend"]) > 0
			and int(balanced["construction_spend"]) > 0,
			"both agents actually build")


func test_greedy_buys_no_infrastructure_ever() -> void:
	# `greedy_growth` is the experiment "growth with nothing bought to support
	# it". If it ever repairs, grids or expands, doc 92's whole growth-versus-
	# infrastructure comparison stops meaning anything.
	var summary: Dictionary = _run("greedy_growth", 1337, 3)["summary"]
	assert_eq(int(summary["grid_placed"]), 0, "greedy never buys a transformer")
	assert_eq(int(summary["repaired"]), 0, "greedy never repairs")
	assert_eq(int(summary["blocks_bought"]), 0, "greedy never buys land")
	assert_eq(int(summary["priority_sets"]), 0, "greedy never touches priority")
	assert_eq(int(summary["tax_changes"]), 0, "greedy leaves the tax rate alone")
	assert_true(int(summary["placed"]) > 0, "but it does grow")


func test_infrastructure_first_buys_civic_before_revenue() -> void:
	var report := _run("infrastructure_first", 1337, 4)
	var sim := CitySim.boot_from_files(1337)
	var first_archetype := ""
	for entry_variant in report["actions"]:
		var entry: Dictionary = entry_variant
		if String(entry["verb"]) == "place" and bool(entry["ok"]):
			first_archetype = String(entry["subject"])
			break
	assert_ne(first_archetype, "", "infrastructure_first placed something")
	var category := sim.catalog.category(first_archetype)
	assert_true(category == "service" or category == "utility",
			"first purchase is civic, got '%s' (%s)" % [first_archetype, category])


# ------------------------------------------------- pass-2 strategy behaviour

func test_tax_squeezer_pins_the_top_detent_and_pays_for_it() -> void:
	# The agent's entire content is doc 03 §2.2's tax knob at TAX_RATE_MAX. It
	# must reach the top detent, reach it once, and be measurably less happy
	# than the identical builder at the founding rate.
	var sim := CitySim.boot_from_files(1337)
	var top := sim.tax_level_count() - 1
	var squeezer: Dictionary = _run("tax_squeezer", 1337)["summary"]
	var balanced: Dictionary = _run("balanced", 1337)["summary"]
	assert_eq(int(squeezer["tax_level_end"]), top,
			"tax_squeezer holds the top detent (level %d)" % top)
	assert_almost_eq(float(squeezer["tax_rate_end"]), sim.tax_rate_for_level(top), 1e-9,
			"and the rate that detent names")
	assert_eq(int(squeezer["tax_changes"]), 1,
			"it moves the slider exactly once, not every hour")
	assert_eq(int(balanced["tax_level_end"]), sim.tax_level(),
			"the control leaves the rate at the founding TAX_RATE_BASE")
	assert_true(float(squeezer["happiness_end"]) < float(balanced["happiness_end"]),
			"the top detent costs happiness (%.2f vs %.2f)"
					% [float(squeezer["happiness_end"]), float(balanced["happiness_end"])])


func test_disaster_neglect_is_balanced_with_maintenance_switched_off() -> void:
	# Single-variable design: `disaster_neglect` must issue NO maintenance verb,
	# while the agent it is derived from issues at least one. Anything else and
	# the pair stops being a controlled comparison.
	var neglect: Dictionary = _run("disaster_neglect", 1337, 3)["summary"]
	var balanced: Dictionary = _run("balanced", 1337, 3)["summary"]
	assert_eq(int(neglect["repaired"]), 0, "neglect never repairs")
	assert_eq(int(neglect["priority_sets"]), 0, "neglect never prioritises")
	assert_eq(int(neglect["grid_placed"]), 0, "neglect never buys grid")
	assert_true(int(balanced["priority_sets"]) > 0,
			"the control DOES set doc 04 §2.4 priority classes")
	assert_eq(int(neglect["tax_level_end"]), int(balanced["tax_level_end"]),
			"and the two agree on the knob they do not differ on")
	assert_true(Playtest.Factory.make("disaster_neglect") is Playtest.Balanced,
			"neglect is literally the balanced agent, one flag down")
	assert_true(Playtest.Factory.make("tax_squeezer") is Playtest.Balanced,
			"and so is the squeezer")


func test_grid_siting_prefers_the_densest_dark_patch() -> void:
	# `best_transformer_tile` is the only judgement the harness makes about
	# where a transformer goes, so it has to be a real one: the tile it picks
	# must be legal, currently unserved, and cover at least as much dark ground
	# as the first tile a naive row-major scan would have taken.
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var dark := api.unserved_tiles()
	assert_true(dark.size() > 0, "the founding core has unserved buildable ground")
	var chosen: Vector2i = api.best_transformer_tile()
	assert_true(dark.has(chosen), "the chosen tile is one of the dark ones")
	assert_true(sim.world.grid.can_place(chosen, Vector2i.ONE), "and it is placeable")
	assert_false(sim.grid.would_serve(chosen), "and nothing serves it yet")
	assert_true(_dark_cover(api, dark, chosen) >= _dark_cover(api, dark, dark[0]),
			"the pick covers at least as much dark ground as the first scan hit")
	# And the command layer accepts it, which is the property the strategies rely
	# on when they spend money against this answer.
	var quote: Dictionary = api.grid_quote("transformer", chosen)
	assert_true(bool(quote["ok"]), "cmd_place_grid_component previews it ok (%s)"
			% String(quote["reason_code"]))
	assert_true(int((quote["payload"] as Dictionary)["cost"]) > 0, "and quotes a price")


static func _dark_cover(api: Playtest.Api, dark: Array[Vector2i], centre: Vector2i) -> int:
	var radius: int = Playtest.Api.TRANSFORMER_L1_RADIUS
	var count := 0
	for tile in dark:
		if maxi(absi(tile.x - centre.x), absi(tile.y - centre.y)) <= radius:
			count += 1
	return count


func test_transformer_radius_constant_tracks_the_live_grid() -> void:
	# The siting heuristic hard-codes doc 04 §8's L1 service radius. If doc 04
	# retunes it, this fails here rather than silently mis-siting every
	# transformer the harness ever buys.
	assert_eq(Playtest.Api.TRANSFORMER_L1_RADIUS,
			int(PowerGrid.TRANSFORMER_SERVICE_RADIUS[0]),
			"harness L1 radius == PowerGrid.TRANSFORMER_SERVICE_RADIUS[0]")


func test_place_into_the_wall_reports_e_unserved() -> void:
	# `greedy_growth`'s wall probe depends on this exact contract: asked for a
	# site nothing serves, the command layer must answer E_UNSERVED and the
	# harness must count it.
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var dark: Vector2i = api.unserved_footprint(Vector2i.ONE)
	assert_true(dark.x >= 0, "the founding core has an unserved 1x1 footprint")
	var result := api.place_at("house", dark)
	assert_false(bool(result["ok"]), "building on dark ground is refused")
	assert_eq(String(result["reason_code"]), "E_UNSERVED", "with doc 04 §2.1's code")
	assert_eq(api.unserved_walls, 1, "and the harness counts the wall")


func test_every_strategy_id_builds_and_runs() -> void:
	for strategy_id in Playtest.STRATEGY_IDS + Playtest.NAMED_ONLY_STRATEGY_IDS:
		var strategy := Playtest.Factory.make(String(strategy_id))
		assert_true(strategy != null, "factory knows '%s'" % String(strategy_id))
		assert_eq(strategy.id(), String(strategy_id), "id() round-trips")
		assert_ne(strategy.describe(), "", "%s documents itself" % String(strategy_id))
	assert_true(Playtest.Factory.make("nonsense") == null, "unknown ids return null")
	# The named-only list is not in `all`, and that is a budget decision worth a
	# test rather than a comment: `collector` is a FINE-path agent and a 21-day
	# fine run is ~60× a coarse one, so putting it in the default matrix would
	# quietly make every `--strategies=all` invocation an hour long.
	for strategy_id in Playtest.NAMED_ONLY_STRATEGY_IDS:
		assert_false(Playtest.STRATEGY_IDS.has(String(strategy_id)),
				"'%s' must stay out of `all`" % String(strategy_id))


# --------------------------------------- the fine slice (Wave 15, RR-86)

## **Sixty game-minutes are one game-hour, to the bit.**
##
## `Collector` needs the seam between game-minutes, so `Runner` cuts the fine
## advance into sixty calls when a strategy asks for it. That slice is only safe
## if it produces the identical city — otherwise every collector measurement is a
## measurement of a *different* game, and the controlled pair doc 92 §39.5 rests
## on stops being controlled.
##
## Asserted on `state_hash()` rather than on the loop's shape, and on an agent
## that does nothing in the seam, so the two arms differ in nothing but the
## slicing.
func test_slicing_an_hour_into_minutes_lands_on_the_same_city() -> void:
	var whole := CitySim.boot_from_files(4242)
	for _h in 6:
		whole.advance_hours(1.0)
	var sliced := CitySim.boot_from_files(4242)
	var idle := Playtest.Factory.make("do_nothing")
	var api := Playtest.Api.new(sliced)
	for h in 6:
		Playtest.Runner.advance_hour_by_minutes(sliced, idle, api, h)
	assert_eq(sliced.state_hash(), whole.state_hash(),
			"sixty advance_fine_n(4) calls must be one advance_fine_n(240)")
	assert_eq(sliced.clock.tick_index, whole.clock.tick_index,
			"and land on the same tick")


## The tap itself, end to end through the harness: a collector run on the fine
## path collects, the money reaches doc 03's own `street` ledger row, and the
## same agent with the tap removed collects nothing.
##
## One game-day, one seed — this is a plumbing test, not a balance measurement.
## The balance measurement is gate 32(f) and the published table is
## `tools/measure_street_arc.gd`.
func test_the_collector_taps_and_the_curriculum_does_not() -> void:
	var played: Dictionary = Rig.run_fine("collector", 1337, 1)["summary"]
	assert_true(int(played["opportunities_collected"]) > 0,
			"the collector took no offers in a whole game-day")
	assert_true(int(played["street_income"]) > 0, "and was paid for none of them")
	assert_true(float(played["street_share_of_net"]) > 0.0,
			"and the share column stayed at zero anyway")
	# Doc 03 §2.5's own row, not the harness's tally — the two agreeing is what
	# says the harness is measuring the game and not itself.
	assert_eq(int((played["lifetime"] as Dictionary)["lifetime_street"]),
			int(played["street_income"]),
			"the harness's tally and doc 03's lifetime row are the same dollars")

	var idle: Dictionary = Rig.run_fine("curriculum", 1337, 1)["summary"]
	assert_eq(int(idle["opportunities_collected"]), 0,
			"`curriculum` is `collector` with the tap removed and must take nothing")
	assert_eq(int(idle["street_income"]), 0)
	assert_almost_eq(float(idle["street_share_of_net"]), 0.0, 1e-12,
			"doc 03 §2.5's `STREET_IDLE_SHARE` zero, measured")


# --------------------------------------------------------- command-layer probe

func test_verb_probe_reports_the_live_command_layer() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	# Wave 1.5 landed every verb doc 93 §B asked for. The probe stays because it
	# is what keeps a mid-wave harness from crashing, but the expectation now is
	# that the whole roster answers.
	for verb in Playtest.KNOWN_VERBS:
		assert_true(api.has_verb(String(verb)),
				"%s is live in sim/city_sim.gd" % String(verb))
	for verb in Playtest.KNOWN_VERBS:
		assert_true(api.verbs.has(String(verb)),
				"%s is probed, present or not" % String(verb))
		var probe: Dictionary = api.verbs[String(verb)]
		assert_true(probe.has("present") and probe.has("args") and probe.has("required"))
	# The two verbs that exist today are probed with their real arity, which is
	# what the optional-verb guard compares against.
	assert_eq(int((api.verbs["cmd_upgrade_building"] as Dictionary)["required"]), 1,
			"cmd_upgrade_building(sim_id, preview = false)")


## **The regression that hid for three waves, made structural** (Wave 26, doc 92
## §67.1, report 98 RR-213, doc 91 A91-D-137).
##
## `KNOWN_VERBS` is the ONLY source of `Api.verbs`, and `has_verb` answers false
## for anything absent from it — so a door that calls `sim.cmd_X()` while `X` is
## not on the list is dead on its first line, silently, forever.
## `Api.upgrade_grid_component` shipped in Wave 22 in exactly that state:
## `cmd_upgrade_grid_component` was never listed, the door returned `E_NO_VERB`
## without logging, and gate 21's capstone went red on main three waves later
## with an action log that showed an idle agent.
##
## The verb-probe test above cannot catch it — it walks the list and asks whether
## each entry is live, which says nothing about a call site the list has never
## heard of. So this walks the OTHER way: every `sim.cmd_*` this harness reaches
## for, read out of its own source, must be on the roster it degrades against.
func test_every_command_the_harness_drives_is_on_the_verb_roster() -> void:
	var source := FileAccess.get_file_as_string("res://tools/playtest.gd")
	assert_true(source.length() > 0, "the harness source is readable")
	var expression := RegEx.new()
	# `sim` is the Api's own field and `api.sim` is how a strategy reaches it.
	assert_eq(expression.compile("\\bsim\\.(cmd_[a-z_]+)\\s*\\("), OK)
	var driven: Dictionary = {}
	for match: RegExMatch in expression.search_all(source):
		driven[match.get_string(1)] = true
	assert_true(driven.size() >= 12,
			"the scan found %d commands, which is too few to be reading the file"
					% driven.size())
	var missing: Array[String] = []
	for verb: String in driven:
		if not Playtest.KNOWN_VERBS.has(verb):
			missing.append(verb)
	missing.sort()
	assert_eq(missing.size(), 0,
			("tools/playtest.gd calls %s but does not list %s in KNOWN_VERBS, so "
					+ "`has_verb` answers false and every door that reaches for "
					+ "it is dead on its first line") % [str(missing), str(missing)])


func test_optional_verbs_degrade_instead_of_crashing() -> void:
	# A harness that dies on a missing or reshaped verb is useless mid-wave.
	# Every wrapped call answers with a reason code either way, so this test
	# keeps passing whether the command layer moves under it or not.
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var calls := {
		"cmd_repair_building": api.repair("H-001"),
		"cmd_demolish_building": api.demolish("NOPE-999"),
		"cmd_buy_block": api.buy_block("B_0_0"),
		"cmd_start_development": api.start_development("B_0_0"),
		"cmd_set_priority": api.set_priority("NOPE-999", "CRITICAL"),
		"cmd_set_tax_level": api.set_tax_level(1),
		"cmd_place_grid_component": api.place_grid_component("transformer", Vector2i(48, 48)),
	}
	for verb in calls:
		var result: Dictionary = calls[verb]
		assert_true(result.has("ok") and result.has("reason_code"),
				"%s answers the CommandQueue contract" % verb)
		if not api.has_verb(String(verb)):
			assert_false(bool(result["ok"]), "%s is absent, so the call must fail" % verb)
			assert_eq(String(result["reason_code"]), "E_NO_VERB",
					"%s degrades with E_NO_VERB" % verb)


func test_purchasable_block_answers_the_doc09_gate() -> void:
	# `balanced` expands through this the day `cmd_buy_block` lands, so the
	# selector must agree with `WorldMap.purchase_allowed` and never offer a
	# block the city already owns.
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var block_id: String = api.purchasable_block()
	if block_id == "":
		# Legal answer: nothing is buyable at city level 0. Prove it.
		for id in sim.world.block_ids_sorted():
			var block: LandBlock = sim.world.block(String(id))
			if block.is_owned():
				continue
			assert_false(bool(sim.world.purchase_allowed(String(id), 0)["ok"]),
					"%s is buyable but the selector missed it" % String(id))
		return
	var chosen: LandBlock = sim.world.block(block_id)
	assert_true(chosen != null, "the selector returned a real block")
	assert_false(chosen.is_owned(), "and one the city does not already own")
	assert_true(bool(sim.world.purchase_allowed(block_id, sim.progression.city_level)["ok"]),
			"%s clears doc 09 §2.5's gate" % block_id)


func test_candidate_site_is_placeable_and_served() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var site: Vector2i = api.candidate_site(Vector2i.ONE)
	assert_true(site.x >= 0, "the starter city has a legal 1x1 site")
	assert_true(sim.world.grid.can_place(site, Vector2i.ONE), "site is buildable")
	assert_true(sim.grid.would_serve(site), "site is inside a transformer's reach")
	var block: LandBlock = sim.world.block_of_tile(site.x, site.y)
	assert_true(block != null and block.is_owned() and block.is_ready(),
			"site sits on an owned, developed block")
	# And the command layer agrees with the harness's preflight.
	assert_true(bool(sim.cmd_place_building("house", site)["ok"]),
			"cmd_place_building accepts what candidate_site offered")


# -------------------------------------------------------------- JSON schema

func test_run_document_has_the_published_schema() -> void:
	var report := _run("balanced", 1337, 1)
	for key in DOC_KEYS:
		assert_true(report.has(key), "run document is missing '%s'" % key)
	assert_eq(int(report["schema_version"]), 2, "doc 92 reads schema_version 2")
	var harness: Dictionary = report["harness"]
	assert_eq(String(harness["mode"]), "coarse")
	assert_eq(int(harness["days"]), 1)
	assert_eq(int(harness["hours"]), 24)
	assert_eq(int(harness["sample_period_hours"]), 1)
	var run_info: Dictionary = report["run"]
	assert_eq(String(run_info["strategy"]), "balanced")
	assert_eq(int(run_info["seed"]), 1337)
	assert_eq((run_info["boot_errors"] as Array).size(), 0, "the city booted clean")


func test_sample_stream_is_hourly_and_well_formed() -> void:
	var report := _run("balanced", 1337, 2)
	var samples: Array = report["samples"]
	assert_eq(samples.size(), 49, "t0 plus one sample per game-hour")
	for index in samples.size():
		var sample: Dictionary = samples[index]
		for key in SAMPLE_KEYS:
			assert_true(sample.has(key), "sample %d missing '%s'" % [index, key])
		assert_eq(int(sample["h"]), index, "samples are contiguous game-hours")
		assert_eq(int(sample["day"]), index / 24)
		assert_true(float(sample["blackout_minutes"]) >= 0.0)
		assert_true(int(sample["metered_buildings"]) > 0)
		assert_true(int(sample["dark_buildings"]) <= int(sample["metered_buildings"]))
	# t0 is the founding snapshot: nothing has settled yet.
	var first: Dictionary = samples[0]
	assert_eq(int(first["treasury"]), 25_000, "doc 03 §2.12 starting treasury")
	assert_almost_eq(float(first["net"]), 0.0, 1e-9, "no hour has been billed at t0")
	# The first settled hour tracks the AS-INTEGRATED founding net (doc 93 §E2):
	# doc 03's worked +$318.77 predates docs 05/10 billing live, and the pass-2
	# figure of 348.7 predates doc 06's live fleet roster replacing doc 03's held
	# `STARTER_VEHICLES` (doc 92 fleet-billing ruling). The ruled anchor is
	# `data/economy.json` `STARTER_NET_PER_HOUR_EXACT`; read it rather than
	# repeating it, so a future re-stamp moves one number and not two.
	var pacing: Dictionary = StarterCityLoader.read_json("res://data/economy.json") \
			.get("pacing_guardrails", {})
	assert_almost_eq(float((samples[1] as Dictionary)["net"]),
			float(pacing["STARTER_NET_PER_HOUR_EXACT"]), 8.0,
			"first settled hour tracks the as-integrated founding net")


func test_summary_and_day_rows_are_complete() -> void:
	var report := _run("greedy_growth", 1337, 2)
	var summary: Dictionary = report["summary"]
	for key in SUMMARY_KEYS:
		assert_true(summary.has(key), "summary is missing '%s'" % key)
	assert_eq(int(summary["days"]), 2)
	assert_eq(int(summary["hours"]), 48)
	assert_eq(int(summary["treasury_start"]), 25_000)
	var day_rows: Array = summary["day_rows"]
	assert_eq(day_rows.size(), 2, "one row per game-day")
	for index in day_rows.size():
		var row: Dictionary = day_rows[index]
		assert_eq(int(row["day"]), index + 1)
		for key in ["treasury", "net_mean_per_hour", "population", "happiness",
				"stability", "city_level", "blackout_minutes", "buildings"]:
			assert_true(row.has(key), "day row missing '%s'" % key)
	assert_true(float(summary["unserved_share"]) >= 0.0
			and float(summary["unserved_share"]) <= 1.0, "share is a fraction")
	assert_true((summary["reason_codes"] as Dictionary).has("OK"),
			"greedy's commands were accepted")


func test_document_survives_a_json_round_trip() -> void:
	# The file on disk is the artifact; anything that cannot round-trip through
	# JSON is a schema bug, not a formatting nit.
	var report := _run("do_nothing", 1337, 1)
	var text := JSON.stringify(report, "\t", true, true)
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary, "the run document is valid JSON")
	var reloaded: Dictionary = parsed
	for key in DOC_KEYS:
		assert_true(reloaded.has(key), "round-tripped document lost '%s'" % key)
	assert_eq(String(reloaded["digest"]), String(report["digest"]))
	assert_eq((reloaded["samples"] as Array).size(), (report["samples"] as Array).size())


func test_writer_produces_a_readable_file() -> void:
	var report := _run("do_nothing", 1337, 1)
	var path := "%s/do_nothing_seed1337_d1_coarse.json" % TEST_OUT_DIR
	Playtest._write_json(path, report)
	assert_true(FileAccess.file_exists(path), "the run file was written to %s" % path)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(parsed is Dictionary, "and it parses back")
	if parsed is Dictionary:
		assert_eq(String((parsed as Dictionary)["digest"]), String(report["digest"]))
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TEST_OUT_DIR)


# ------------------------------------------------------------------- options

func test_option_parsing() -> void:
	var opts := Playtest.Options.parse(PackedStringArray([
			"--days=3", "--seeds=1,2", "--strategies=balanced,do_nothing",
			"--mode=coarse", "--out=res://tmp", "--no-json", "--quiet",
			"--experiment=tax_curve"]))
	assert_eq((opts.errors as Array).size(), 0, ", ".join(opts.errors))
	assert_eq(opts.days, 3)
	assert_eq(opts.hours(), 72)
	assert_eq(opts.seeds, [1, 2] as Array[int])
	assert_eq(opts.strategies, ["balanced", "do_nothing"] as Array[String])
	assert_eq(opts.mode, "coarse")
	assert_eq(opts.out_dir, "res://tmp")
	assert_eq(opts.experiment, "tax_curve")
	assert_false(opts.write_json)
	assert_true(opts.quiet)


func test_option_defaults_and_errors() -> void:
	var defaults := Playtest.Options.parse(PackedStringArray([]))
	assert_eq((defaults.errors as Array).size(), 0)
	assert_eq(defaults.days, 21, "doc 92 pass 2's default horizon")
	assert_eq(defaults.mode, "fine", "the default is the path the player plays")
	assert_eq((defaults.seeds as Array).size(), 3, "3+ seeds per strategy")
	# Seven since Wave 9: doc 92 §22's `curriculum`, the student the goal
	# curriculum is paced against. It joins `STRATEGY_IDS` — and therefore a
	# no-argument `tools/playtest.gd` run — but deliberately NOT
	# `tests/balance_matrix.gd`'s default six, which is doc 92's fitted sample.
	assert_eq((defaults.strategies as Array).size(), 7)
	assert_true((defaults.strategies as Array).has("curriculum"))
	assert_eq(defaults.experiment, "", "the matrix runs unless one is named")
	assert_eq(defaults.difficulty, Difficulty.DEFAULT_PRESET,
			"the harness founds on the preset every doc 92 table is measured on")
	var bad := Playtest.Options.parse(PackedStringArray([
			"--nonsense", "--mode=warp", "--strategies=cheat",
			"--experiment=teleport", "--difficulty=nightmare"]))
	assert_eq((bad.errors as Array).size(), 5, "every bad option is reported: %s"
			% ", ".join(bad.errors))


## Doc 92 §32.4 / §29.5 ranked item 4. `Balanced`'s reserve floor was a flat
## $12,000 that happened to equal `crisis`'s ENTIRE founding purse, so the agent
## whose reserve is `max(floor, one game-day of expense)` had `spare = 0` on the
## first game-hour and never issued a command in 21 game-days. The constant is
## now the fraction it always was — and the whole claim is that it reproduces
## `standard` to the dollar, which is why this test asserts a literal 12,000
## there and only a scaling relationship elsewhere.
func test_the_reserve_floor_is_a_fraction_of_the_founding_purse() -> void:
	var difficulty := Difficulty.load_from_file()
	assert_true(difficulty.is_valid(), ", ".join(difficulty.errors))
	var expected := {}
	for preset in Difficulty.PRESETS:
		var purse := float(int(difficulty.row_of("economic", preset)["starting_treasury"]))
		expected[preset] = int(Playtest.Balanced.RESERVE_FLOOR_FRACTION * purse)
	assert_eq(int(expected["standard"]), 12_000,
			"the control's floor is the pass-2 constant, to the dollar")
	assert_eq(int(expected["casual"]), 16_800)
	assert_eq(int(expected["hard"]), 8_640)
	assert_eq(int(expected["crisis"]), 5_760)
	# And it is what the live agent actually holds, on a city founded on the
	# preset — read off the treasury row, so a save-restored city gets it too.
	for preset in Difficulty.PRESETS:
		var sim := CitySim.boot_from_files(1337, preset)
		var agent := Playtest.Balanced.new()
		agent.note_founding_purse(Playtest.Api.new(sim))
		assert_eq(agent.operating_reserve(), int(expected[preset]),
				("on %s the agent holds its founding-purse floor before the first "
						+ "settled hour has told it what a game-day of expense costs")
						% preset)
	# The pathology this closes, stated as an inequality: on `crisis` the flat
	# floor was >= the purse, so `balance - reserve` could never be positive.
	var crisis_purse := int(difficulty.row_of("economic", "crisis")["starting_treasury"])
	assert_true(int(expected["crisis"]) < crisis_purse,
			"a reserve floor a city cannot afford on its founding hour is a lock, "
					+ "not a reserve")


# =================== Wave 26 — the utility planner (doc 92 §67, report 98 §70)

## **Every exit from the copper door is in the action log, with the command's own
## reason on it** (RR-213). Both early returns used to leave through a bare
## `CommandQueue.fail` that never reached `_log`, and the third overwrote the
## preview's reason with `E_BLOCKED` — so the log could not tell "the agent never
## tried" from "the agent tried and the grid said no", which is exactly the
## reading that hid `E_NO_VERB` for three waves.
func test_the_grid_upgrade_door_logs_every_refusal() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	assert_true(api.has_verb("cmd_upgrade_grid_component"),
			"the verb Wave 22 forgot to register")
	var before: int = api.actions.size()
	var nothing := api.upgrade_grid_component("")
	assert_false(bool(nothing["ok"]))
	assert_eq(api.actions.size(), before + 1, "an empty target is still a log row")
	assert_eq(String((api.actions[before] as Dictionary)["reason"]), "E_UNKNOWN_COMPONENT")
	var unknown := api.upgrade_grid_component("NOPE-999")
	assert_false(bool(unknown["ok"]))
	assert_eq(api.actions.size(), before + 2)
	assert_eq(String((api.actions[before + 1] as Dictionary)["reason"]),
			"E_UNKNOWN_COMPONENT",
			"the COMMAND's reason code, not a word the harness made up")
	# A real component the city cannot pay for: the reason is doc 03's, and it is
	# `E_FUNDS` rather than `E_BLOCKED`.
	var transformer := ""
	for id: Variant in sim.grid.component_ids_of_kind(&"transformer"):
		transformer = String(id)
		break
	assert_ne(transformer, "", "the founding city has a transformer")
	sim.treasury.balance = 1
	var broke := api.upgrade_grid_component(transformer)
	assert_false(bool(broke["ok"]))
	assert_eq(String((api.actions[api.actions.size() - 1] as Dictionary)["reason"]),
			"E_FUNDS", "the price is why, and the log says the price is why")


## **Doc 05 §2.5's supply term is a CHAIN, not a roster** (RR-215). `upstream_cap
## = min(Σ source yield, Σ treatment throughput)` and each pump's share is its
## slice of THAT, so a pump upgrade raises a treatment-bound zone's supply by
## exactly zero. The old door tried pumps, then sources, then treatment, in that
## fixed order; this one walks the chain and puts the smallest term first.
func test_the_water_door_raises_the_term_that_binds() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var zone: PressureZone = null
	for raw: Variant in sim.water.topology.zones:
		var candidate: PressureZone = raw
		if not candidate.dead and not candidate.treatment_ids.is_empty() \
				and not candidate.pump_ids.is_empty():
			zone = candidate
			break
	assert_ne(zone, null, "the founding city has a zone with a treatment train and a pump")
	var order := api.supply_chain_order(zone)
	assert_true(order.size() >= 2, "the chain has more than one node in it")
	var kind_of := func(id: String) -> String:
		return String((sim.water.nodes[id] as WaterNode).variant)
	# Whatever the founding numbers are, the FIRST id must belong to the term
	# whose total is smallest — the assertion is the rule, not the seed's answer.
	var totals := {
		"source": api._zone_source_yield(zone),
		"treatment": api._zone_treatment(zone),
		"pump": api._zone_pump_rated(zone),
	}
	var smallest := ""
	for key: String in ["pump", "source", "treatment"]:
		if smallest == "" or float(totals[key]) < float(totals[smallest]):
			smallest = key
	assert_eq(kind_of.call(order[0]), smallest,
			("the chain order opens on the term that binds (source %.1f / "
					+ "treatment %.1f / pump %.1f)") % [float(totals["source"]),
					float(totals["treatment"]), float(totals["pump"])])
	assert_eq(api.binding_supply_kind(zone.zone_key), smallest,
			"and the placement door agrees with the upgrade door about which it is")
	for id: String in order:
		assert_ne(kind_of.call(id), "tank",
				"a tank stores water the zone never had and is never in the chain")


## **The relief reads the refusal** (RR-213). `Api.blocked_upgrade` asks the grid
## with the SAME ×1.15 margin `CitySim.cmd_upgrade_building` used, so the
## component it names is the one that actually refused, and it forwards doc 04's
## own word for what that component IS — because the answer to a transformer at
## 1.009 is a bigger transformer and the answer to a feeder at 0.93 is copper.
func test_blocked_upgrade_names_the_component_that_bound_and_its_kind() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	# Drive the founding city into a power refusal on one archetype by starving
	# the grid rather than by waiting 25 game-days for one.
	for id: Variant in sim.grid.component_ids_of_kind(&"transformer"):
		sim.grid.set_level(String(id), 1)
	sim.treasury.balance = 50_000_000
	var rows: Array[Dictionary] = []
	var power_rows := 0
	# Doc 09 §2.14.2's level-7 roster, which is every archetype doc 02 ships.
	for archetype: String in ["house", "store", "apartment", "office", "high_rise",
			"data_center", "police_station", "fire_station", "power_facility",
			"substation", "water_facility", "construction_yard"]:
		var row := api.blocked_upgrade(archetype)
		if row.is_empty():
			continue
		rows.append(row)
		# **The contract, both halves.** A power refusal names the component doc
		# 04 says binds AND doc 04's own word for what it is; anything else names
		# neither, because a `power_at` on an `E_CONDITION` row would send the
		# next reader to buy copper for a building that needs a paint job.
		assert_true(row.has("power_at") and row.has("power_kind"),
				"%s: the row carries both fields either way" % archetype)
		if String(row["blocker"]) == "E_POWER_HEADROOM":
			power_rows += 1
			assert_ne(String(row["power_at"]), "",
					"%s: a power refusal names its component" % archetype)
			assert_true(["transformer", "feeder", "substation"].has(
					String(row["power_kind"])),
					"%s: doc 04's own kind for it, got '%s'"
							% [archetype, String(row["power_kind"])])
			assert_true(sim.grid.has_component(String(row["power_at"]))
							or sim.buildings.has(String(row["power_at"])),
					"%s: the named component exists on one side of C-30's split"
							% archetype)
		else:
			assert_eq(String(row["power_at"]), "",
					"%s: %s is not a power refusal and must name no component"
							% [archetype, String(row["blocker"])])
			assert_eq(String(row["power_kind"]), "",
					"%s: nor a kind" % archetype)
	assert_true(rows.size() > 0,
			("a founding city with every transformer at doc 04's 50 kW rung has at "
					+ "least one archetype whose next rung the gate refuses "
					+ "(%d rows, %d of them for power)") % [rows.size(), power_rows])


# ===========================================================================
# Wave 30 — the agent lays a main (doc 93 §BH, doc 92 §67.9 item 2)
# ===========================================================================

## The furthest owned, developed, un-piped tile on the founding city, scanned
## row-major so the answer is the same on every machine. Doc 05 §2.3's factor is
## `1 − 0.10 × (d − 2)`, so a tile at d = 8 sees 0.40 of whatever its zone has —
## under the 0.55 gate at any healthy zone pressure.
static func _far_dry_tile(sim: CitySim, api: Playtest.Api, want: int) -> Vector2i:
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			var tile := Vector2i(x, z)
			var block: LandBlock = sim.world.block_of_tile(x, z)
			if block == null or not block.is_owned() or not block.is_ready():
				continue
			if sim.water.topology.distance_at_tile(tile) < want:
				continue
			if api._main_layable(tile):
				return tile
	return Vector2i(-1, -1)


## **The purchase `tools/playtest.gd` could not make until this wave.** Doc 92
## §67.9 item 2 and A91-D-123's closing row: `cmd_place_water_main` was probed,
## listed and called by nothing. The route is doc 05's own
## `WaterSystem.lateral_tiles`, it starts ON the network because §2.2's
## connectivity is physical, and the whole of what it buys is §2.3's `d`.
func test_the_agent_lays_a_service_main_and_it_takes_the_tile_factor_to_one() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	sim.treasury.balance = 20_000_000
	var target := _far_dry_tile(sim, api, 8)
	assert_ne(target, Vector2i(-1, -1),
			"the founding city has owned, developed ground eight tiles from a main")
	assert_almost_eq(sim.water.topology.factor_at_tile(target), 0.40, 0.001,
			"1 − 0.10 × (8 − 2), doc 05 §2.3, before anything is laid")

	var run := api.water_main_run(target, "service")
	assert_true(run.size() >= 2, "a run of at least two tiles, or it is not a main")
	assert_false(sim.water.nearest_main_tile(run[0], 0).is_empty(),
			"the run STARTS on a live main tile — §2.2's connectivity is physical")
	assert_eq(run[run.size() - 1], target, "…and it ENDS on the tile that was refused")

	# Doc 03 §2.13(g): `service` is $286/tile, and the quote is the command's own.
	var per_tile := sim.econ_curves.water_main_cost_per_tile("service",
			float(sim.treasury.difficulty().get("M_build", 1.0)))
	assert_eq(per_tile, 286, "doc 03 §2.13(g)'s service main, at standard M_build")
	var quote := api.water_main_quote(target, "service")
	assert_eq(quote, run.size() * per_tile)

	var balance_before := sim.treasury.balance
	assert_true(bool(api.place_water_main(target, "service")["ok"]))
	assert_eq(sim.treasury.balance, balance_before - quote,
			"doc 03 billed exactly the quote")
	assert_eq(api.water_main_tiles, run.size())
	assert_eq(api.water_main_spend, quote)
	assert_eq(sim.water.topology.distance_at_tile(target), 0,
			"the tile is ON the main now")
	assert_almost_eq(sim.water.topology.factor_at_tile(target), 1.0, 0.001,
			"…so §2.3's factor is 1.0 and the gate's second arm has nothing to say")


## **The other wall: `feed_capacity`, the one term of §2.5's chain that is not a
## node** (doc 92 §67.8, doc 93 §BD6). `WaterTopology._resolve_supply_chain`
## counts only mains INCIDENT TO A SUPPLY NODE'S TILE, so the run has to start at
## the plant — which is why `Api.water_main_run` takes an explicit tap.
func test_a_trunk_laid_at_the_plant_raises_the_term_no_node_can_raise() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	sim.treasury.balance = 20_000_000
	var zone: PressureZone = null
	for raw: Variant in sim.water.topology.zones:
		var candidate: PressureZone = raw
		if not candidate.dead and not candidate.live_pump_ids.is_empty():
			zone = candidate
			break
	assert_ne(zone, null, "the founding city has a zone with a live pump")
	var key := zone.zone_key
	var before := zone.feed_capacity_m3h
	var node: WaterNode = sim.water.nodes[String(zone.live_pump_ids[0])]
	var step := Vector2i(-1, -1)
	for candidate: Vector2i in [Vector2i(1, 0), Vector2i(0, 1),
			Vector2i(-1, 0), Vector2i(0, -1)]:
		if api._main_layable(node.tile + candidate) \
				and api._main_layable(node.tile + candidate * 2):
			step = candidate
			break
	assert_ne(step, Vector2i(-1, -1), "there is clear ground beside the plant")
	var target: Vector2i = node.tile + step * 2
	assert_true(bool(api.place_water_main(target, "trunk", node.tile)["ok"]),
			"a run whose `path[0]` is a facility's own terminal tile is CONNECTED")
	# `rebuild_zones()` builds new `PressureZone` objects; the old handle is stale.
	var after: PressureZone = sim.water.topology.zone_by_key(key)
	assert_ne(after, null)
	assert_almost_eq(after.feed_capacity_m3h,
			before + sim.water.data.main_capacity("trunk"), 0.001,
			"the trunk's whole nameplate joins §2.5's min-cut, because it touches "
					+ "the supply tile")


## Both searches are TOTAL, and what they answer has to be true of the city they
## answered about — the shape this project keeps filing is a harness read that
## nothing checks against the sim it came from.
func test_the_two_main_searches_answer_only_what_the_sim_agrees_with() -> void:
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	sim.treasury.balance = 20_000_000
	var tile := api.water_distance_blocked_tile()
	if tile.x >= 0:
		var found := ""
		for id: Variant in sim.buildings:
			if sim.water.demand.access_tile(String(id)) == tile:
				found = String(id)
				break
		assert_ne(found, "", "the tile it names belongs to a building")
		var b: Building = sim.buildings[found]
		var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
		var delta := float(next_stats.get("water_demand", 0.0)) \
				- float(b.stats.get("water_demand", 0.0))
		assert_eq(String(sim.water.can_upgrade_water(found, delta)["reason"]),
				WaterSystem.BLOCKED_DISTANCE,
				"…and doc 05 refuses that building for DISTANCE, not for capacity")
	else:
		# The founding city's own answer, and it is an assertion either way: no
		# standing building is one rung short AND refused for distance.
		assert_eq(tile, Vector2i(-1, -1))
	var trunk := api.mains_bound_trunk(Playtest.Balanced.MAINS_TRUNK_TILES)
	if trunk.is_empty():
		var mains_bound := 0
		for raw: Variant in sim.water.topology.zones:
			var z: PressureZone = raw
			if not z.dead and String(sim.water.supply_chain_of(z)["binding"]) == "mains":
				mains_bound += 1
		assert_eq(mains_bound, 0,
				"it stands down only when NO zone binds on its mains")
	else:
		var z: PressureZone = sim.water.topology.zone_by_key(String(trunk["zone"]))
		assert_ne(z, null)
		assert_eq(String(sim.water.supply_chain_of(z)["binding"]), "mains")
		assert_ne(sim.water.node_at_tile(trunk["tap"]), "",
				"the tap is a facility's own terminal tile, which is what "
						+ "`feed_capacity` counts and what `E_NOT_CONNECTED` accepts")


## **KNOB 4 ships OFF, and the A/B pair differs in exactly that one field**
## (doc 93 §BH5, doc 92 §73.4). This is the same controlled-pair discipline
## `tax_squeezer` and `disaster_neglect` are built on, and it is asserted rather
## than commented because the whole value of the measurement is that one knob
## separates the two runs. A second difference introduced later — a cooldown, a
## band, an extra purchase — would make doc 92 §73.4's table a comparison of two
## agents instead of a measurement of one rule.
func test_the_service_main_knob_is_off_by_default_and_is_the_only_difference() -> void:
	var taught := Playtest.Factory.make("curriculum")
	var probe := Playtest.Factory.make("curriculum_service_mains")
	assert_ne(taught, null)
	assert_ne(probe, null)
	assert_true(taught.plans_water, "the taught route plans its water (KNOB 3)")
	assert_false(taught.lays_service_mains,
			"…and does NOT lay service mains: doc 92 §73.4 measured seed 9001's "
					+ "one zone reaching supply 0.0 when it does")
	assert_true(probe.plans_water)
	assert_true(probe.lays_service_mains, "the A/B arm is the knob, switched on")
	# Every other knob and cursor identical, so the pair is controlled.
	assert_eq(probe.maintains, taught.maintains)
	assert_eq(probe.tax_target, taught.tax_target)
	assert_eq(probe.describe() == taught.describe(), false,
			"and it says which one it is")
