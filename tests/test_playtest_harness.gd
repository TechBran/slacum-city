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
	assert_true(int(greedy["placed"]) > int(balanced["placed"]),
			"greedy builds more than balanced")


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
	assert_true(api.has_verb("cmd_place_building"), "the place verb exists today")
	assert_true(api.has_verb("cmd_upgrade_building"), "the upgrade verb exists today")
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
	# Doc 93 §B is landing in parallel; a harness that dies on a missing verb is
	# useless mid-wave. Every optional call answers with a reason code either
	# way, so this test keeps passing as those verbs land.
	var sim := CitySim.boot_from_files(1337)
	var api := Playtest.Api.new(sim)
	var calls := {
		"cmd_repair_building": api.repair("H-001"),
		"cmd_buy_block": api.buy_block("B_0_0"),
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
	assert_eq(int(report["schema_version"]), 1, "doc 92 reads schema_version 1")
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
	# The first settled hour is doc 03's founding ledger anchor, +$318.77/gh.
	assert_almost_eq(float((samples[1] as Dictionary)["net"]), 318.77, 6.0,
			"first settled hour tracks the doc 03 §2.12 founding net")


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
			"--mode=coarse", "--out=res://tmp", "--no-json", "--quiet"]))
	assert_eq((opts.errors as Array).size(), 0, ", ".join(opts.errors))
	assert_eq(opts.days, 3)
	assert_eq(opts.hours(), 72)
	assert_eq(opts.seeds, [1, 2] as Array[int])
	assert_eq(opts.strategies, ["balanced", "do_nothing"] as Array[String])
	assert_eq(opts.mode, "coarse")
	assert_eq(opts.out_dir, "res://tmp")
	assert_false(opts.write_json)
	assert_true(opts.quiet)


func test_option_defaults_and_errors() -> void:
	var defaults := Playtest.Options.parse(PackedStringArray([]))
	assert_eq((defaults.errors as Array).size(), 0)
	assert_eq(defaults.days, 14, "doc 92's default horizon")
	assert_eq(defaults.mode, "fine", "the default is the path the player plays")
	assert_eq((defaults.seeds as Array).size(), 3, "3+ seeds per strategy")
	assert_eq((defaults.strategies as Array).size(), 4)
	var bad := Playtest.Options.parse(PackedStringArray([
			"--nonsense", "--mode=warp", "--strategies=cheat"]))
	assert_eq((bad.errors as Array).size(), 3, "every bad option is reported: %s"
			% ", ".join(bad.errors))
