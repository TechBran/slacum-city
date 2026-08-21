extends SimTest
## Doc 03 §2.9 / §3.4 — the difficulty file, its loader and its seam.
##
## The defect this file closes (doc 91 A91-D-19) was not a wrong number: it was
## that three of four authored presets were **unreachable by any code path**, so
## nothing could have been wrong with them. The tests are therefore mostly about
## REACHABILITY and about the two identities the seam has to hold:
##
##   1. **`standard` is what shipped.** The default preset must reproduce the
##      pre-difficulty binary bit-for-bit — same treasury, same knobs, same
##      hashes — or every number in doc 92 stops meaning what it says.
##   2. **A preset is a property of a city, not of a process.** Booting on a
##      preset, founding on it at tick 0, and loading a save that was written on
##      it must all produce the same city; and no path may change one mid-life
##      (doc 93 §K1).
##
## Everything else here is the schema: a missing row, a nested table, a knob on
## three presets out of four and a non-monotone multiplier are all load errors,
## because §2.9 rule 1 says a missing row is an error and never a default.

const DIFFICULTY_PATH := "res://data/difficulty.json"
const DIRECTOR_PATH := "res://data/director.json"
const INCIDENTS_PATH := "res://data/incidents.json"
const ECONOMY_PATH := "res://data/economy.json"


func _raw() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIFFICULTY_PATH))
	return parsed if parsed is Dictionary else {}


func _loaded(preset: String = Difficulty.DEFAULT_PRESET) -> Difficulty:
	var out := Difficulty.load_from_file()
	out.select(preset)
	return out


# ===========================================================================
# The file
# ===========================================================================

func test_the_file_exists_and_loads_clean() -> void:
	var difficulty := Difficulty.load_from_file()
	assert_eq(str(difficulty.errors), "[]", "data/difficulty.json loads")
	assert_true(difficulty.is_valid())
	assert_eq(str(difficulty.preset_names()),
			'["casual", "standard", "hard", "crisis"]', "§2.9 rule 1, in order")
	assert_eq(difficulty.default_preset(), "standard")
	assert_eq(difficulty.preset, "standard", "a fresh loader opens on the default")


func test_every_section_carries_every_preset() -> void:
	var difficulty := Difficulty.load_from_file()
	for section: String in Difficulty.SECTIONS:
		for preset: String in Difficulty.PRESETS:
			var row := difficulty.row_of(section, preset)
			assert_false(row.is_empty(), "%s.%s" % [section, preset])
			for key: Variant in row:
				var kind := typeof(row[key])
				assert_true(kind == TYPE_INT or kind == TYPE_FLOAT or kind == TYPE_BOOL,
						"%s.%s.%s is a scalar (§3.4 rule 3)"
								% [section, preset, String(key)])


func test_the_economic_table_is_the_one_doc_03_authors() -> void:
	# §2.9's table, transcribed here so the file cannot be edited without a test
	# noticing. Twelve knobs × four presets, and this is the whole surface
	# A91-D-19 said was unreachable.
	var expected := {
		"casual":   {"M_rev": 1.15, "M_exp": 0.85, "M_land": 0.85, "M_dev": 0.85,
				"M_build": 0.90, "M_repair": 0.70, "starting_treasury": 35000,
				"OFF_TAU_HOURS": 120, "offline_damage_cap_fraction": 0.10,
				"REV_FLOOR_FRACTION": 0.25, "CREDIT_APR_PER_GAME_DAY": 0.004,
				"relief_grants_per_era": 4},
		"standard": {"M_rev": 1.00, "M_exp": 1.00, "M_land": 1.00, "M_dev": 1.00,
				"M_build": 1.00, "M_repair": 1.00, "starting_treasury": 25000,
				"OFF_TAU_HOURS": 90, "offline_damage_cap_fraction": 0.20,
				"REV_FLOOR_FRACTION": 0.18, "CREDIT_APR_PER_GAME_DAY": 0.008,
				"relief_grants_per_era": 3},
		"hard":     {"M_rev": 0.92, "M_exp": 1.12, "M_land": 1.15, "M_dev": 1.15,
				"M_build": 1.10, "M_repair": 1.35, "starting_treasury": 18000,
				"OFF_TAU_HOURS": 75, "offline_damage_cap_fraction": 0.30,
				"REV_FLOOR_FRACTION": 0.14, "CREDIT_APR_PER_GAME_DAY": 0.014,
				"relief_grants_per_era": 2},
		"crisis":   {"M_rev": 0.85, "M_exp": 1.25, "M_land": 1.30, "M_dev": 1.30,
				"M_build": 1.20, "M_repair": 1.60, "starting_treasury": 12000,
				"OFF_TAU_HOURS": 60, "offline_damage_cap_fraction": 0.45,
				"REV_FLOOR_FRACTION": 0.10, "CREDIT_APR_PER_GAME_DAY": 0.022,
				"relief_grants_per_era": 0},
	}
	var difficulty := Difficulty.load_from_file()
	for preset: String in Difficulty.PRESETS:
		var row := difficulty.row_of("economic", preset)
		var wanted: Dictionary = expected[preset]
		assert_eq(row.size(), wanted.size(), "%s knob count" % preset)
		for key: Variant in wanted:
			assert_almost_eq(float(row.get(key, -999.0)), float(wanted[key]), 1e-9,
					"economic.%s.%s" % [preset, String(key)])


func test_the_pressure_and_escalation_rows_arrived_intact() -> void:
	# The move out of data/director.json and data/incidents.json is a MOVE:
	# doc 07 §8.3's and doc 06 §8's numbers, unchanged, in their new home.
	var difficulty := Difficulty.load_from_file()
	var pressure := {
		"casual":   [0.60, 2.00, 0.80, 1.50, true],
		"standard": [1.00, 1.00, 1.00, 1.00, true],
		"hard":     [1.45, 0.75, 1.20, 0.70, true],
		"crisis":   [2.00, 0.50, 1.45, 0.50, false],
	}
	for preset: String in Difficulty.PRESETS:
		var row := difficulty.row_of("pressure", preset)
		var wanted: Array = pressure[preset]
		assert_almost_eq(float(row["tp_rate_mult"]), float(wanted[0]), 1e-9, preset)
		assert_almost_eq(float(row["cooldown_mult"]), float(wanted[1]), 1e-9, preset)
		assert_almost_eq(float(row["severity_mult"]), float(wanted[2]), 1e-9, preset)
		assert_almost_eq(float(row["warning_lead_mult"]), float(wanted[3]), 1e-9, preset)
		assert_eq(bool(row["soft_suppression"]), bool(wanted[4]), preset)
	var escalation := {
		"casual":   [0.75, 0.80, 1.2], "standard": [1.00, 1.00, 1.6],
		"hard":     [1.35, 1.20, 1.9], "crisis":   [1.60, 1.40, 2.2],
	}
	for preset: String in Difficulty.PRESETS:
		var row := difficulty.row_of("escalation", preset)
		var wanted: Array = escalation[preset]
		assert_almost_eq(float(row["escalation_mult"]), float(wanted[0]), 1e-9, preset)
		assert_almost_eq(float(row["generation_mult"]), float(wanted[1]), 1e-9, preset)
		assert_almost_eq(float(row["OFFLINE_RESPONSE_TIME_MULT"]), float(wanted[2]),
				1e-9, preset)
	# Doc 08 §2.3's knob, authored at §12 and never filed until now.
	for pair: Array in [["casual", 0.50], ["standard", 1.00], ["hard", 1.30],
			["crisis", 1.60]]:
		assert_almost_eq(float(difficulty.row_of("offline", String(pair[0]))
				["difficulty_offline_mult"]), float(pair[1]), 1e-9, String(pair[0]))


## §2.9 rule 2, enforced in the three files the knobs came out of. This is the
## test that stops the scattering coming back.
func test_no_difficulty_scalar_lives_outside_the_one_file() -> void:
	var director: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(DIRECTOR_PATH))
	assert_false(director.has("_difficulty_fallback"),
			"director.json no longer mirrors the pressure rows")
	assert_false(director.has("difficulty"))
	assert_false(director.has("repair_cost_mult"))
	var incidents: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(INCIDENTS_PATH))
	assert_false(incidents.has("difficulty_escalation"),
			"incidents.json no longer carries the escalation rows")
	var economy: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(ECONOMY_PATH))
	var offline: Dictionary = economy.get("offline", {})
	assert_false(offline.has("OFF_TAU_HOURS"),
			"OFF_TAU_HOURS is a difficulty scalar and left economy.json")
	# And the loaders REFUSE a file that grows one back.
	var tables := DirectorTables.new()
	var poisoned: Dictionary = (JSON.parse_string(
			FileAccess.get_file_as_string(DIRECTOR_PATH)) as Dictionary)
	poisoned["_difficulty_fallback"] = {"standard": {}}
	tables.load_from(poisoned)
	assert_true(str(tables.errors).contains("difficulty.json"),
			"DirectorTables refuses the mirror: %s" % str(tables.errors))


func test_the_compiled_mirror_cannot_drift_from_the_file() -> void:
	# `Treasury.DIFFICULTY_STANDARD` is what a treasury built with no difficulty
	# falls back to. It is a mirror and not an authority, and this is what keeps
	# it one.
	var row := Difficulty.load_from_file().row_of("economic", "standard")
	assert_eq(row.size(), Treasury.DIFFICULTY_STANDARD.size())
	for key: Variant in Treasury.DIFFICULTY_STANDARD:
		assert_true(row.has(key), "difficulty.json carries %s" % String(key))
		assert_almost_eq(float(row[key]), float(Treasury.DIFFICULTY_STANDARD[key]),
				1e-12, String(key))


# ===========================================================================
# The schema — every rule refuses something
# ===========================================================================

func _base() -> Dictionary:
	return _raw().duplicate(true)


func test_a_missing_row_is_a_load_error_and_never_a_default() -> void:
	var data := _base()
	(data["economic"] as Dictionary).erase("hard")
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("economic.hard"), str(difficulty.errors))


func test_a_knob_on_three_presets_out_of_four_is_refused() -> void:
	# Not the same failure as a missing ROW: the row is there, one knob is not,
	# and under a `.get(key, 1.0)` reader that would have been a silent nominal
	# on exactly one difficulty — which is the shape of A91-D-19 itself.
	var data := _base()
	((data["economic"] as Dictionary)["hard"] as Dictionary).erase("M_land")
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("M_land"), str(difficulty.errors))


func test_a_nested_table_is_refused() -> void:
	var data := _base()
	((data["economic"] as Dictionary)["casual"] as Dictionary)["M_rev"] = {"a": 1}
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("scalar"), str(difficulty.errors))


func test_a_non_monotone_multiplier_is_refused() -> void:
	var data := _base()
	((data["economic"] as Dictionary)["hard"] as Dictionary)["M_build"] = 0.5
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("monotone"), str(difficulty.errors))


func test_a_scale_with_no_declared_direction_is_refused() -> void:
	var data := _base()
	for preset: String in Difficulty.PRESETS:
		((data["offline"] as Dictionary)[preset] as Dictionary)["mystery_mult"] = 1.0
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("_direction"), str(difficulty.errors))


func test_a_fifth_section_is_refused() -> void:
	# §3.4 rule 2's whole purpose: a fifth doc cannot quietly add a fifth scalar.
	var data := _base()
	data["morale"] = {"casual": {}, "standard": {}, "hard": {}, "crisis": {}}
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("morale"), str(difficulty.errors))


func test_a_renamed_preset_is_refused() -> void:
	var data := _base()
	((data["meta"] as Dictionary)["presets"] as Array)[2] = "brutal"
	var difficulty := Difficulty.new()
	assert_false(difficulty.load_from(data))
	assert_true(str(difficulty.errors).contains("presets"), str(difficulty.errors))


func test_select_refuses_a_name_that_is_not_a_preset() -> void:
	var difficulty := Difficulty.load_from_file()
	assert_false(difficulty.select("nightmare"))
	assert_eq(difficulty.preset, "standard", "and does not move")
	assert_true(difficulty.select("crisis"))
	assert_almost_eq(difficulty.number("economic", "M_repair"), 1.60, 1e-9)
	assert_false(difficulty.flag("pressure", "soft_suppression"))


# ===========================================================================
# The seam — what the presets actually reach
# ===========================================================================

func test_the_default_preset_is_what_shipped() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_eq(str(sim.boot_errors), "[]")
	assert_eq(sim.difficulty_preset(), "standard")
	assert_eq(sim.treasury.balance, 25000, "doc 03 §2.9's standard founding purse")
	var row := sim.treasury.difficulty()
	for key: Variant in Treasury.DIFFICULTY_STANDARD:
		assert_almost_eq(float(row[key]), float(Treasury.DIFFICULTY_STANDARD[key]),
				1e-12, String(key))
	assert_almost_eq(sim.director.knob("tp_rate_mult"), 1.0, 1e-12)
	assert_almost_eq(sim.director.knob("severity_mult"), 1.0, 1e-12)
	assert_true(sim.director.soft_suppression_enabled())
	assert_almost_eq(sim.incident_world.difficulty_escalation_mult(), 1.0, 1e-12)
	assert_almost_eq(sim.incident_world.difficulty_generation_mult(), 1.0, 1e-12)


func test_every_preset_reaches_every_reader() -> void:
	# The A91-D-19 test: three quarters of the authored table used to be
	# unreachable. Each of these is a live read on a booted city.
	var wanted := {
		"casual":   [35000, 0.90, 0.70, 0.60, 0.75, 0.80, 120.0],
		"standard": [25000, 1.00, 1.00, 1.00, 1.00, 1.00, 90.0],
		"hard":     [18000, 1.10, 1.35, 1.45, 1.35, 1.20, 75.0],
		"crisis":   [12000, 1.20, 1.60, 2.00, 1.60, 1.40, 60.0],
	}
	for preset: String in Difficulty.PRESETS:
		var sim := CitySim.boot_from_files(1337, preset)
		var row: Array = wanted[preset]
		assert_eq(str(sim.boot_errors), "[]", preset)
		assert_eq(sim.difficulty_preset(), preset)
		assert_eq(sim.treasury.balance, int(row[0]), "%s starting treasury" % preset)
		assert_almost_eq(float(sim.treasury.difficulty()["M_build"]), float(row[1]),
				1e-9, "%s M_build" % preset)
		assert_almost_eq(float(sim.treasury.difficulty()["M_repair"]), float(row[2]),
				1e-9, "%s M_repair" % preset)
		assert_almost_eq(sim.director.knob("tp_rate_mult"), float(row[3]), 1e-9,
				"%s pressure" % preset)
		assert_almost_eq(sim.incident_world.difficulty_escalation_mult(),
				float(row[4]), 1e-9, "%s escalation" % preset)
		assert_almost_eq(sim.incident_world.difficulty_generation_mult(),
				float(row[5]), 1e-9, "%s generation" % preset)
		# §2.11's taper is a difficulty knob and reads off the same row.
		assert_almost_eq(sim.economy.offline_yield_mult(
				4.0 + float(row[6])), exp(-1.0), 1e-9, "%s OFF_TAU" % preset)
		assert_eq(sim.director.difficulty, preset, "and the Director is pinned")


func test_a_preset_moves_the_price_a_player_is_quoted() -> void:
	# `M_land` and `M_dev` are doc 03 §2.7/§2.8's difficulty-at-spend-time terms,
	# and land is the cleanest demonstration: the price is a pure function of the
	# block and the row, so nothing about the run can explain the difference.
	var land: Dictionary = {}
	var raw: Dictionary = {}
	var develop: Dictionary = {}
	for preset: String in Difficulty.PRESETS:
		var sim := CitySim.boot_from_files(1337, preset)
		var block_id: String = sim.world.block_ids_sorted()[0]
		var inputs := sim.land_price_inputs(block_id)
		var block: LandBlock = sim.world.block(block_id)
		land[preset] = sim.economy.land_price(inputs)
		raw[preset] = sim.economy.land_price_raw(inputs)
		develop[preset] = sim.economy.development_total_cost(
				String(block.dev_terrain), float(inputs["d"]),
				block.arterial_connections,
				float(sim.treasury.difficulty().get("M_dev", 1.0)))
	for table: Dictionary in [land, develop]:
		assert_true(int(table["casual"]) < int(table["standard"]),
				"casual %d < standard %d" % [int(table["casual"]), int(table["standard"])])
		assert_true(int(table["standard"]) < int(table["hard"]))
		assert_true(int(table["hard"]) < int(table["crisis"]))
	# And the price IS the authored knob applied to the standard price, checked on
	# `land_price_raw` — doc 03 §2.7 rounds the shown price to `PRICE_ROUNDING`
	# ($100), so a ratio of two *quoted* figures measures the rounding rather
	# than the knob ($8,500 × 0.85 = $7,225 → the player is quoted $7,200).
	for pair: Array in [["casual", 0.85], ["hard", 1.15], ["crisis", 1.30]]:
		assert_almost_eq(float(raw[pair[0]]) / float(raw["standard"]),
				float(pair[1]), 1e-9, "M_land reaches the price as itself: %s"
						% String(pair[0]))


func test_founding_a_city_is_the_same_city_as_booting_one() -> void:
	# The shell founds a city by KEEPING the sim it booted with (`game/main.gd`
	# holds a paused starter city behind the door), so the preset arrives after
	# the boot. These two paths must be the same city, bit for bit, or the door
	# would be a second game.
	for preset: String in Difficulty.PRESETS:
		var booted := CitySim.boot_from_files(4242, preset)
		var founded := CitySim.boot_from_files(4242)
		assert_true(founded.found_with_difficulty(preset), preset)
		assert_eq(founded.state_hash(), booted.state_hash(),
				"%s: founded == booted at tick 0" % preset)
		booted.advance_coarse_hours(24, false)
		founded.advance_coarse_hours(24, false)
		assert_eq(founded.state_hash(), booted.state_hash(),
				"%s: and 24 game-hours later" % preset)


func test_a_played_city_refuses_to_change_difficulty() -> void:
	# Doc 93 §K1: the preset is chosen once. There is no `cmd_set_difficulty`,
	# and the founding call is not one in disguise.
	var sim := CitySim.boot_from_files(1337)
	sim.advance_coarse_hours(1, false)
	assert_false(sim.found_with_difficulty("crisis"), "tick_index != 0")
	assert_eq(sim.difficulty_preset(), "standard")
	assert_almost_eq(float(sim.treasury.difficulty()["M_repair"]), 1.00, 1e-12)
	# An unknown name is refused even at tick 0.
	var fresh := CitySim.boot_from_files(1337)
	assert_false(fresh.found_with_difficulty("nightmare"))
	assert_eq(fresh.difficulty_preset(), "standard")


# ===========================================================================
# Persistence (doc 08 §2.8, city section v6)
# ===========================================================================

func test_the_preset_is_part_of_the_city() -> void:
	for preset: String in Difficulty.PRESETS:
		var live := CitySim.boot_from_files(9001, preset)
		live.advance_coarse_hours(6, false)
		var blob := live.canonical_capture()
		# A fresh process boots on the DEFAULT and has to learn the preset from
		# the save — which is the whole point of the section.
		var restored := CitySim.boot_from_files(9001)
		assert_eq(restored.difficulty_preset(), "standard", "before the load")
		restored.restore_state(blob)
		assert_eq(restored.difficulty_preset(), preset, "after it")
		assert_almost_eq(float(restored.treasury.difficulty()["M_exp"]),
				float(live.treasury.difficulty()["M_exp"]), 1e-12, preset)
		assert_almost_eq(restored.director.knob("severity_mult"),
				live.director.knob("severity_mult"), 1e-12, preset)
		assert_almost_eq(restored.incident_world.difficulty_escalation_mult(),
				live.incident_world.difficulty_escalation_mult(), 1e-12, preset)
		assert_eq(restored.state_hash(), live.state_hash(), "%s save→load" % preset)
		live.advance_coarse_hours(12, false)
		restored.advance_coarse_hours(12, false)
		assert_eq(restored.state_hash(), live.state_hash(),
				"%s save→load→advance is bit-identical" % preset)


## Mode invariance, on the terms doc 01 §9 item 4 actually states them: a coarse
## catch-up is NOT a fine catch-up of the same duration for a stochastic system,
## and the coarse contract binds the two only to **±5 % in expectation**. So this
## measures an expectation — three seeds — and not one run, which would be
## measuring whether a single incident happened to land on either side of an
## hour boundary.
##
## The structural half is exact and is asserted as such: same tick index, same
## roster, same city level. Only the dollars are allowed to differ.
##
## Measured 2026-08-20 (doc 92 §29.4): mean signed delta over seeds 1337/4242/9001
## at 24 game-hours is +0.23 % casual, +0.12 % standard, −0.08 % hard, −0.07 %
## crisis. The per-seed spread is a FIXED ~$720–800 — one incident's repair bill
## landing on one side of an hour boundary — which reads as ±6.5 % against
## crisis's $12,000 purse and ±2.7 % against standard's $25,000 one. That is the
## purse moving, not the invariance.
func test_mode_invariance_holds_on_every_preset() -> void:
	for preset: String in Difficulty.PRESETS:
		var total := 0.0
		var runs := 0
		for seed_value: int in [1337, 4242, 9001]:
			var coarse := CitySim.boot_from_files(seed_value, preset)
			var fine := CitySim.boot_from_files(seed_value, preset)
			coarse.advance_coarse_hours(24, false)
			fine.advance_hours(24.0)
			assert_eq(coarse.clock.tick_index, fine.clock.tick_index, preset)
			assert_eq(coarse.roster_ids().size(), fine.roster_ids().size(),
					"%s: same roster either way" % preset)
			assert_eq(coarse.progression.city_level, fine.progression.city_level,
					"%s: same city level either way" % preset)
			total += 100.0 * float(coarse.treasury.balance - fine.treasury.balance) \
					/ maxf(1.0, absf(float(fine.treasury.balance)))
			runs += 1
		var mean := total / float(runs)
		assert_true(absf(mean) <= 5.0,
				"%s: coarse vs fine mean %+0.2f %% is inside doc 01's ±5 %% band"
						% [preset, mean])


func test_the_section_version_moved_and_an_old_save_defaults() -> void:
	assert_eq(CitySim.SAVE_SECTION_VERSION, 6, "the difficulty epoch")
	# A v5 body already names the preset — every save the game has written does —
	# so the migrator is the identity function on it.
	var live := CitySim.boot_from_files(1337, "hard")
	var body := live.canonical_capture()
	var migrated := live.migrate_save_section(body.duplicate(true), 5)
	assert_eq(String((migrated["director"] as Dictionary)["difficulty"]), "hard",
			"a v5 body that names its preset keeps it")
	# The one body it is not the identity on: no `difficulty` at all.
	var bare := body.duplicate(true)
	(bare["director"] as Dictionary).erase("difficulty")
	var stamped := live.migrate_save_section(bare, 5)
	assert_eq(String((stamped["director"] as Dictionary)["difficulty"]),
			Difficulty.DEFAULT_PRESET, "and one that does not gets the default")
	# The default is not a guess: under v5 only `standard` was reachable.
	var loaded := CitySim.boot_from_files(1337)
	loaded.restore_state(stamped)
	assert_eq(loaded.difficulty_preset(), "standard")


func test_a_save_with_a_preset_the_binary_does_not_know_still_loads() -> void:
	# Doc 08 §2.8: the restore is TOTAL. A city is worth more than a string.
	var live := CitySim.boot_from_files(1337)
	var body := live.canonical_capture()
	(body["director"] as Dictionary)["difficulty"] = "brutal"
	var restored := CitySim.boot_from_files(1337)
	restored.restore_state(body)
	assert_eq(restored.difficulty_preset(), Difficulty.DEFAULT_PRESET)
	assert_almost_eq(float(restored.treasury.difficulty()["M_rev"]), 1.0, 1e-12)
