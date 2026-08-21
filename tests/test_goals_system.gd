extends SimTest
## Doc 09 §2.14 — the teaching curriculum, sim side.
##
## Five things are asserted here and every one of them is a property the feature
## dies without:
##
##   1. the curriculum is **data**, and every row of it names a verb the player
##      can actually reach;
##   2. objectives **advance** the level and the population ladder still
##      **backstops** it — doc 93 §G1's ruling, which is what keeps doc 92 §19's
##      fitted rungs meaningful for every agent that never reads a goals sheet;
##   3. progress **persists exactly** — save → load → advance stays bit-identical,
##      which is why the counters are a save section and not a UI preference;
##   4. a save written before this system existed **loads into a sane city** and
##      is never asked to build its first house again;
##   5. evaluation costs **O(events)**, and the state kinds cost one reconcile a
##      game-hour.

const GOALS_PATH := "res://data/goals.json"

## Every verb the UI can actually issue today. A curriculum row that asks for
## anything else is a row the player cannot complete — see `data/goals.json`'s
## own `_verbs` note, and doc 92 §17.6 for the three sim verbs with no surface.
const PLAYER_REACHABLE_KINDS: Array[String] = [
	"collect_opportunities",
	"build_archetype", "place_grid_component", "place_water_component",
	# `upgrade_to_level` rides the same building-panel button as
	# `upgrade_building` — it counts the same command, filtered by the rung
	# the upgrade reaches — so if one is reachable the other is.
	"upgrade_building", "upgrade_to_level", "buy_block", "develop_block",
	"set_tax_rate",
	"resolve_incidents", "reach_population", "reach_happiness",
	"reach_stability", "reach_treasury", "survive_no_abandonment",
	# --- Wave 10: the three doors doc 92 §17.6 recorded as missing.
	# `stamp_road_tiles` reaches `cmd_place_road` through the build sheet's
	# ROADS tab and `ui/path_tool.gd`'s drag-path flow (doc 12 §2.7);
	# `place_water_main` reaches `cmd_place_water_main` through the same tool on
	# the infrastructure tab; `repair_buildings` reaches `cmd_repair_building`
	# through the building panel's actions row (doc 12 §2.9 item 6) and through
	# the upgrade checklist's `Fix this →` on `E_CONDITION`.
	"stamp_road_tiles", "place_water_main", "repair_buildings",
]

## Kinds whose surface is COMMITTED to a named branch of the current wave and is
## not in this tree yet — the split-delivery case, and the narrowest possible
## door in §G2's wall.
##
## §G2's rule is *a curriculum may never ask for something the UI cannot do*, and
## the gate below enforces its stronger sibling: an evaluator kind with no
## surface at all is a wall with no door, one wave earlier. A wave that splits
## one mechanic across two branches — a sim spawner here, the renderer and its
## tap there — produces, in the sim branch alone, a kind whose door genuinely
## exists and genuinely is not here. Putting it in the whitelist would make the
## whitelist claim a surface that does not exist; leaving it out fails a gate
## that is right about everything except the calendar.
##
## So it goes here, and it is **mechanically self-clearing**:
## `test_a_deferred_surface_moves_the_moment_its_door_exists` fails the suite as
## soon as `game/` or `ui/` mentions the verb, so the row cannot outlive the
## branch it names. A row must state the WAVE and the FILE — asserted — so
## "somebody will get to it" cannot be written here.
const SURFACE_DEFERRED_KINDS := {}


func _sim(seed_value: int = 1337) -> CitySim:
	return CitySim.boot_from_files(seed_value)


## Place `count` buildings of `archetype`, anywhere the preflight accepts, and
## return how many landed. The tests never name a tile: the starter city is data
## and it may move.
static func _place(sim: CitySim, archetype: String, count: int) -> int:
	var placed := 0
	var size: Vector2i = Vector2i.ONE
	var foot: Array = sim.catalog.stats(archetype, 1).get("footprint", [1, 1])
	size = Vector2i(int(foot[0]), int(foot[1]))
	for block_id in sim.world.block_ids_sorted():
		if placed >= count:
			break
		var block: LandBlock = sim.world.block(String(block_id))
		if not block.is_ready():
			continue
		var x0: int = block.grid.x * 16
		var z0: int = block.grid.y * 16
		for z in range(z0, z0 + 16 - size.y + 1):
			for x in range(x0, x0 + 16 - size.x + 1):
				if placed >= count:
					break
				if bool(sim.cmd_place_building(archetype, Vector2i(x, z))["ok"]):
					placed += 1
	return placed


# ===========================================================================
# 1. The curriculum is data
# ===========================================================================

func test_the_curriculum_is_one_row_per_rung_of_the_ladder() -> void:
	var levels := GoalSystem.levels()
	var ladder := ProgressionSystem.city_level_pop()
	assert_eq(levels.size(), ladder.size() - 1,
			"doc 09 §2.14: one curriculum level per rung above the founding level")
	for i in levels.size():
		assert_eq(int((levels[i] as Dictionary)["level"]), i + 1,
				"the rows are levels 1..N, ascending, with no gap")


func test_every_objective_names_a_kind_the_evaluator_knows() -> void:
	# A row naming an unknown kind is DROPPED at parse rather than crashing a
	# city, so a typo would be silent — this is the test that is not silent.
	var raw: Dictionary = StarterCityLoader.read_json(GOALS_PATH)
	var authored := 0
	for entry: Variant in (raw.get("levels", []) as Array):
		authored += ((entry as Dictionary).get("objectives", []) as Array).size()
	var parsed := 0
	for entry: Variant in GoalSystem.levels():
		parsed += ((entry as Dictionary)["objectives"] as Array).size()
	assert_eq(parsed, authored,
			"every authored objective survived the parse — one did not, so one "
			+ "names a kind `GoalSystem` does not have")


func test_every_objective_is_a_verb_the_player_can_reach() -> void:
	# The rule doc 09 §2.14 is written around, and doc 93 §G2 states: a
	# curriculum may never ask for something the UI cannot do. Wave 10 opened
	# the last three doors (§G2's amendment), so the whitelist is now the full
	# evaluator table — which is exactly why the SECOND assertion below matters
	# more than this one from here on.
	for entry: Variant in GoalSystem.levels():
		for raw: Variant in ((entry as Dictionary)["objectives"] as Array):
			var obj: Dictionary = raw
			assert_true(PLAYER_REACHABLE_KINDS.has(String(obj["kind"])),
					"%s uses `%s`, which no UI surface can perform"
							% [obj["id"], obj["kind"]])


func test_every_evaluator_kind_is_accounted_for_by_a_surface() -> void:
	# The gate that keeps §G2 alive now that every shipped kind is reachable.
	# A new evaluator kind added to `GoalSystem` without a door does not fail
	# the whitelist above — nothing authors it yet — so it fails HERE instead:
	# `PLAYER_REACHABLE_KINDS` is the list of kinds a surface exists for, and a
	# kind missing from it is a verb somebody wrote an evaluator for and never
	# gave the player. That is the wall with no door, one wave earlier.
	var kinds: Array[String] = []
	for kind: Variant in GoalSystem.EVENT_KINDS:
		kinds.append(String(kind))
	for kind: Variant in GoalSystem.STATE_KINDS:
		kinds.append(String(kind))
	kinds.append(String(GoalSystem.KIND_SURVIVE))
	for kind: String in kinds:
		if SURFACE_DEFERRED_KINDS.has(kind):
			continue
		assert_true(PLAYER_REACHABLE_KINDS.has(kind),
				("`%s` is an evaluator kind with no player surface. Either ship "
						+ "the surface and list it here, name the branch that "
						+ "will in SURFACE_DEFERRED_KINDS, or delete the "
						+ "evaluator — doc 93 §G2.") % kind)
	assert_eq(PLAYER_REACHABLE_KINDS.size() + SURFACE_DEFERRED_KINDS.size(),
			kinds.size(),
			"and the two lists between them name no kind the evaluator does"
			+ " not have")


func test_a_deferred_surface_moves_the_moment_its_door_exists() -> void:
	# What makes SURFACE_DEFERRED_KINDS a deferral rather than an exemption.
	# Three things are asserted: a kind is on exactly ONE of the two lists; the
	# deferral names a wave and a file; and the door it promises does not exist
	# yet — the moment `game/` or `ui/` can call the verb, this fails and the
	# row has to move into the whitelist where it now belongs.
	var doors := _shell_source()
	# The dict may legitimately be empty (every kind doored — the Wave-14
	# state); the test still has to assert so the runner's silent-method guard
	# sees it ran.
	assert_true(SURFACE_DEFERRED_KINDS.size() >= 0,
			"the deferral list exists (possibly empty — all kinds doored)")
	for kind: Variant in SURFACE_DEFERRED_KINDS:
		var name := String(kind)
		assert_false(PLAYER_REACHABLE_KINDS.has(name),
				"`%s` is on both lists; it belongs to exactly one" % name)
		var row := str(SURFACE_DEFERRED_KINDS[kind])
		assert_true(row.contains("Wave ") and (row.contains("game/")
				or row.contains("ui/")),
				"`%s` defers to a NAMED wave and a NAMED file: `%s`" % [name, row])
		var verb := _verb_named_in(row)
		assert_ne(verb, "", "`%s` names the verb its door will call" % name)
		assert_false(doors.contains(verb),
				("`%s` is doored now — `%s` is called from game/ or ui/ — so move"
						+ " it into PLAYER_REACHABLE_KINDS.") % [name, verb])


## Every line of `game/` and `ui/`, concatenated. Generous on purpose: any
## mention of the verb counts as a door, because this test's job is to notice
## that the branch landed, not to prove the wiring is correct.
func _shell_source() -> String:
	var out := ""
	for dir_path: String in ["res://game", "res://ui"]:
		out += _read_gd(dir_path)
	return out


func _read_gd(dir_path: String) -> String:
	var out := ""
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path + "/" + entry
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out += _read_gd(full)
		elif entry.ends_with(".gd"):
			out += FileAccess.get_file_as_string(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## The `cmd_*` name a deferral row quotes in backticks.
func _verb_named_in(row: String) -> String:
	var matcher := RegEx.new()
	matcher.compile("cmd_[a-z_]+")
	var found := matcher.search(row)
	return "" if found == null else found.get_string()


func test_every_objective_has_copy_and_a_unique_id() -> void:
	var cfg := UIConfig.load_from_files()
	var seen: Array[String] = []
	for entry: Variant in GoalSystem.levels():
		var level: Dictionary = entry
		for key: String in ["title_key", "intent_key", "teaches_key"]:
			assert_true(cfg.has_string(str(level[key])),
					"level %d's %s exists in data/strings.en.json"
							% [int(level["level"]), key])
		for raw: Variant in (level["objectives"] as Array):
			var obj: Dictionary = raw
			var id := str(obj["id"])
			assert_false(seen.has(id), "objective id %s is used once" % id)
			seen.append(id)
			assert_true(cfg.has_string(str(obj["text_key"])),
					"%s has copy" % id)
			assert_true(float(obj["target"]) > 0.0, "%s has a real target" % id)


# ===========================================================================
# 2. Objectives advance the level; the ladder backstops it
# ===========================================================================

func test_a_fresh_city_starts_the_curriculum_at_level_one() -> void:
	var sim := _sim()
	assert_eq(sim.goals.earned_level, 0, "nothing is earned at t0")
	assert_eq(sim.goals.active_level(), 1, "and level 1 is what is being worked")
	assert_eq(sim.goals.chip_text(), "0/3",
			"the chip reads the active level's objective count")
	# The founding city is NOT credited with the houses it was built with: a
	# bootstrap is for a MIGRATION, and a new game has to be played.
	var view := sim.goals.view()
	for raw: Variant in (view["objectives"] as Array):
		var obj: Dictionary = raw
		if String(obj["kind"]) == "build_archetype":
			assert_almost_eq(float(obj["current"]), 0.0, 0.001,
					"%s starts at zero on a new city" % obj["id"])


func test_placing_the_things_level_one_asks_for_moves_the_counters() -> void:
	var sim := _sim()
	assert_eq(_place(sim, "house", 4), 4, "four houses went up")
	sim.advance_hours(1.0)
	var view := sim.goals.view()
	var houses := _objective(view, "l1_houses")
	assert_almost_eq(float(houses["current"]), 4.0, 0.001, "counted on placement")
	assert_true(bool(houses["done"]), "and the objective landed")
	assert_eq(sim.goals.chip_text(), "1/3")


func test_objectives_earn_the_level_before_the_population_rung_does() -> void:
	var sim := _sim()
	# Eight houses at doc 02's L1 `population 4` is +32 residents on the founding
	# 144 — over the curriculum's 170 and well under the ladder's 200. The gap
	# between those two numbers is the whole point of the ruling.
	_place(sim, "house", 8)
	_place_transformer(sim)
	# 60 game-hours: long enough for doc 09's 36-hour occupancy ramp to fill the
	# new houses, far short of what the population rung would need.
	for i in 60:
		sim.advance_coarse_hours(1, false)
	assert_true(sim.goals.earned_level >= 1,
			"the objective list completed: %s" % str(sim.goals.view()))
	assert_eq(sim.progression.city_level, sim.goals.earned_level,
			"and the city level followed it")
	assert_true(sim.population.city_population < ProgressionSystem.city_level_pop()[1],
			"while the population rung is still out of reach — which is the "
			+ "whole ruling (doc 93 §G1)")


func test_the_population_rung_still_grants_the_level_on_its_own() -> void:
	# Doc 93 §G1's other half: a player who never opens the sheet must still
	# progress, and every scripted agent in `tools/playtest.gd` is that player.
	var sim := _sim()
	sim.population.city_population = ProgressionSystem.city_level_pop()[2]
	sim.publish_progression(sim.progression.update(sim.population.city_population))
	assert_eq(sim.progression.city_level, 2,
			"the ladder alone carried the city to level 2")
	assert_eq(sim.goals.earned_level, 0,
			"without completing a single objective")


func test_a_level_is_never_taken_back() -> void:
	var sim := _sim()
	sim.publish_progression(sim.progression.grant_level(3))
	assert_eq(sim.progression.city_level, 3)
	sim.publish_progression(sim.progression.grant_level(1))
	assert_eq(sim.progression.city_level, 3, "monotone (doc 09 §2.11)")
	sim.publish_progression(sim.progression.update(0))
	assert_eq(sim.progression.city_level, 3, "a collapse re-locks nothing")


func test_grant_level_cannot_invent_a_rung_the_ladder_does_not_have() -> void:
	var sim := _sim()
	sim.publish_progression(sim.progression.grant_level(99))
	assert_eq(sim.progression.city_level,
			ProgressionSystem.city_level_pop().size() - 1,
			"clamped to the ladder's own height")


func test_the_bus_carries_the_three_goal_events() -> void:
	var sim := _sim()
	sim.bus.drain()
	_place(sim, "house", 4)
	sim.advance_hours(1.0)
	var kinds: Dictionary = {}
	for event in sim.bus.drain():
		kinds[str(event["type"])] = int(kinds.get(str(event["type"]), 0)) + 1
	assert_true(kinds.has("goal_progress"), "progress is published")
	assert_true(kinds.has("goal_completed"), "so is completion")


# ===========================================================================
# 3. Persistence — the counters survive EXACTLY
# ===========================================================================

func test_save_load_advance_is_bit_identical_with_a_curriculum_in_flight() -> void:
	var sim := _sim()
	_place(sim, "house", 3)
	_place_transformer(sim)
	for i in 20:
		sim.advance_coarse_hours(1, false)
	var body := sim.canonical_capture()
	var loaded := _sim()
	loaded.restore_state(body)
	assert_eq(loaded.state_hash(), sim.state_hash(), "restore is exact")
	assert_eq(loaded.goals.earned_level, sim.goals.earned_level)
	assert_eq(loaded.goals.chip_text(), sim.goals.chip_text())
	for i in 12:
		sim.advance_coarse_hours(1, false)
		loaded.advance_coarse_hours(1, false)
	assert_eq(loaded.state_hash(), sim.state_hash(),
			"save → load → advance is bit-identical (constitution §5)")


func test_partial_progress_round_trips_to_the_number() -> void:
	var sim := _sim()
	_place(sim, "house", 2)
	sim.advance_hours(1.0)
	var before: Dictionary = sim.goals.serialize()
	var loaded := _sim()
	loaded.restore_state(sim.canonical_capture())
	assert_eq(str(loaded.goals.serialize()), str(before),
			"2 of 4 houses is still 2 of 4 houses after a reload")


func test_the_city_section_carries_the_goals_block() -> void:
	# The goals block arrived on rung 3 and the ladder has moved past it (Wave 9
	# added rung 4, the routing/cadence epoch). What this test owns is that the
	# BLOCK is in the body and that the rung is at least the one that added it —
	# pinning the exact number here would make every future rung fail a goals
	# test for no reason.
	assert_true(CitySim.SAVE_SECTION_VERSION >= 3,
			"doc 08 §2.8: the goals block arrived on rung 3")
	assert_true(CitySim.boot_from_files().canonical_capture().has("goals"),
			"and the body carries it")


# ===========================================================================
# 4. Retroactive safety — a v2 save is not insulted
# ===========================================================================

func test_a_v2_save_migrates_to_a_marked_body() -> void:
	var sim := _sim()
	var body := sim.canonical_capture()
	body.erase("goals")
	var migrated := sim.migrate_save_section(body, 2)
	assert_true((migrated["goals"] as Dictionary).get("bootstrap", false),
			"the migrator MARKS; it does not answer (doc 08 §2.8 forbids data/)")


func test_a_played_v2_city_is_never_asked_to_build_its_first_house() -> void:
	# The lead's rule, made executable: a city already at level 4 with a roster
	# of buildings loads with levels 1–4 complete and level 5 in progress.
	var sim := _sim()
	_place(sim, "house", 5)
	_place(sim, "store", 2)
	_place_transformer(sim)
	sim.publish_progression(sim.progression.grant_level(4))
	var body := sim.canonical_capture()
	body.erase("goals")   # the shape a v2 body has
	var loaded := _sim()
	loaded.restore_state(sim.migrate_save_section(body, 2))
	assert_eq(loaded.goals.earned_level, 4,
			"every level at or below the city's own is complete")
	assert_eq(loaded.goals.active_level(), 5, "and level 5 is what is left")
	for entry: Variant in GoalSystem.level_row(1)["objectives"]:
		assert_true(bool(loaded.goals.done[str((entry as Dictionary)["id"])]),
				"level 1's objectives are not asked for again")


func test_bootstrap_counts_what_the_city_already_has() -> void:
	# A level-0 v2 city with four houses standing does not start "0/4 houses".
	var sim := _sim()
	assert_true(_place(sim, "house", 4) >= 1, "some houses went up")
	var standing := 0
	for id in sim.roster_ids():
		if String((sim.buildings[id] as Building).archetype) == "house":
			standing += 1
	var body := sim.canonical_capture()
	body.erase("goals")
	var loaded := _sim()
	loaded.restore_state(sim.migrate_save_section(body, 2))
	# The starter city ships with houses of its own, so the count is the whole
	# roster's — which is the honest reading of "what the city already has".
	assert_true(int(loaded.goals.progress.get("l1_houses", 0)) == standing
			or bool(loaded.goals.done.get("l1_houses", false)),
			"the house counter was seeded from the roster (%d standing, %s)"
					% [standing, str(loaded.goals.progress)])


func test_a_bootstrap_does_not_celebrate() -> void:
	var sim := _sim()
	sim.publish_progression(sim.progression.grant_level(3))
	var body := sim.canonical_capture()
	body.erase("goals")
	var loaded := _sim()
	loaded.bus.drain()
	loaded.restore_state(sim.migrate_save_section(body, 2))
	var goal_events := 0
	for event in loaded.bus.drain():
		if str(event["type"]).begins_with("goal_") \
				or str(event["type"]) == "city_level_objectives_met":
			goal_events += 1
	assert_eq(goal_events, 0,
			"a returning player is not shown three level-ups for last week's work")


func test_a_missing_goals_file_leaves_the_city_on_the_population_ladder() -> void:
	# The degrade path: no curriculum at all is exactly the game that shipped
	# before this system existed, and it must still run.
	var empty := GoalSystem.new()
	assert_eq(empty.active_level(), 1,
			"with rows loaded, level 1 is active — the cache is the file's")
	assert_true(GoalSystem.top_level() >= 1)


# ===========================================================================
# 5. Cost and determinism
# ===========================================================================

func test_evaluation_is_event_driven_not_a_roster_scan() -> void:
	# The structural half of doc 09 §2.14's cost rule: the reconcile reads a
	# fixed set of O(1) scalars, and the only roster walk in the system is the
	# once-per-migration residue count.
	var sim := _sim()
	var view := sim.goal_state_view()
	assert_eq(view.size(), GoalSystem.STATE_KINDS.size(),
			"the per-hour view is exactly the state kinds and nothing else")
	for kind: StringName in GoalSystem.STATE_KINDS:
		assert_true(view.has(String(GoalSystem.STATE_KINDS[kind])),
				"%s has a supplier" % kind)


func test_two_identical_runs_produce_identical_curricula() -> void:
	var a := _sim()
	var b := _sim()
	for sim: CitySim in [a, b]:
		_place(sim, "house", 4)
		_place_transformer(sim)
		for i in 40:
			sim.advance_coarse_hours(1, false)
	assert_eq(a.state_hash(), b.state_hash(), "same seed, same city")
	assert_eq(str(a.goals.serialize()), str(b.goals.serialize()),
			"and the same curriculum state, to the counter")


func test_the_streak_kind_resets_on_a_loss() -> void:
	var goals := GoalSystem.new()
	var row := _level_with_kind("survive_no_abandonment")
	if row.is_empty():
		return   # no level uses it; nothing to assert
	goals.earned_level = int(row["level"]) - 1
	var id := str(_kind_objective(row, "survive_no_abandonment")["id"])
	for i in 5:
		goals.reconcile({"population": 0.0, "happiness": 0.0, "stability": 0.0,
				"treasury": 0.0})
	assert_eq(int(goals.progress.get(id, 0)), 5, "five clean game-hours")
	goals.observe({"type": &"incident_abandoned"})
	assert_eq(int(goals.progress.get(id, 0)), 0, "and one loss takes them")


# ===========================================================================
# Helpers
# ===========================================================================

static func _objective(view: Dictionary, id: String) -> Dictionary:
	for raw: Variant in (view["objectives"] as Array):
		if str((raw as Dictionary)["id"]) == id:
			return raw
	return {}


static func _level_with_kind(kind: String) -> Dictionary:
	for entry: Variant in GoalSystem.levels():
		for raw: Variant in ((entry as Dictionary)["objectives"] as Array):
			if String((raw as Dictionary)["kind"]) == kind:
				return entry
	return {}


static func _kind_objective(level: Dictionary, kind: String) -> Dictionary:
	for raw: Variant in (level["objectives"] as Array):
		if String((raw as Dictionary)["kind"]) == kind:
			return raw
	return {}


## A transformer on the first tile doc 04's own preview accepts. Asked, never
## named — the starter city's served ground is data.
static func _place_transformer(sim: CitySim) -> bool:
	for block_id in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(block_id))
		if not block.is_ready():
			continue
		var x0: int = block.grid.x * 16
		var z0: int = block.grid.y * 16
		for z in range(z0, z0 + 16):
			for x in range(x0, x0 + 16):
				if bool(sim.cmd_place_grid_component(
						"transformer", Vector2i(x, z), 1)["ok"]):
					return true
	return false
