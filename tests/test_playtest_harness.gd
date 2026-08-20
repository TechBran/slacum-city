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
	for strategy_id in Playtest.STRATEGY_IDS:
		var strategy := Playtest.Factory.make(String(strategy_id))
		assert_true(strategy != null, "factory knows '%s'" % String(strategy_id))
		assert_eq(strategy.id(), String(strategy_id), "id() round-trips")
		assert_ne(strategy.describe(), "", "%s documents itself" % String(strategy_id))
	assert_true(Playtest.Factory.make("nonsense") == null, "unknown ids return null")


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
	var bad := Playtest.Options.parse(PackedStringArray([
			"--nonsense", "--mode=warp", "--strategies=cheat",
			"--experiment=teleport"]))
	assert_eq((bad.errors as Array).size(), 4, "every bad option is reported: %s"
			% ", ".join(bad.errors))
