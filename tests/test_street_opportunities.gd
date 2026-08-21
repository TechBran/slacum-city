extends SimTest
## Doc 06 §2.16 — the opportunity layer, held down.
##
## Six properties, and each one is a thing the layer could plausibly get wrong:
##
##   1. the spawner is a pure function of the city (determinism);
##   2. a crook appears where the police are not (the coverage response — the
##      hook the player asked for by name);
##   3. a tap pays, once, on its own ledger line, and a stale marker refuses;
##   4. a save taken mid-crook restores the crook, and the two cities advance
##      together afterwards;
##   5. nothing accrues while the player is away, and the `street` stream does
##      not move a single position on the coarse path;
##   6. the kerb the sim picks is the kerb the renderer draws.

const KERB_BITS := [1, 2, 4, 8]


func _sim(seed_value: int = 1337) -> CitySim:
	var sim := CitySim.boot_from_files(seed_value)
	assert_eq(str(sim.boot_errors), str(PackedStringArray()), "clean boot")
	return sim


## Drain the bus and keep the events of one type. The bus is the only channel —
## `bus.observer` is doc 09's curriculum and must not be stolen by a test.
func _drain(sim: CitySim, wanted: String) -> Array:
	var out: Array = []
	for event in sim.bus.drain():
		if String(event.get("type", "")) == wanted:
			out.append(event)
	return out


## Advance an hour at a time until something is standing on the street, up to
## `limit`. Returns whether it found one — the spawner is stochastic and a test
## that assumed a fixed hour would be pinning a draw rather than a property.
func _advance_until_live(sim: CitySim, limit: int = 24) -> bool:
	for i in limit:
		sim.advance_hours(1.0)
		if sim.street.live_count() > 0:
			return true
	return false


# ===========================================================================
# 1. Determinism
# ===========================================================================

func test_two_cities_on_one_seed_spawn_the_same_street() -> void:
	var a := _sim()
	var b := _sim()
	a.advance_hours(24.0)
	b.advance_hours(24.0)
	var spawned_a := _drain(a, "opportunity_spawned")
	var spawned_b := _drain(b, "opportunity_spawned")
	assert_true(spawned_a.size() >= 4,
			"24 game-hours is enough street life to be worth comparing: %d"
			% spawned_a.size())
	assert_eq(JSON.stringify(spawned_a), JSON.stringify(spawned_b),
			"same seed, same offers — id, kind, tile, kerb, dollars and expiry")
	assert_eq(a.state_hash(), b.state_hash(), "and the same city underneath")


## Drive the spawner ALONE across `hours` game-hours, at exactly the cadence the
## phase adapter drives it at, and return the events it produced.
##
## This is the measurement rig for the two statistical tests below, and it is
## worth saying why it is not `sim.advance_hours()`: a whole-city advance costs
## ~0.4 s per game-hour, so the 400 game-hours these two want would be three
## minutes of suite time to sample a system that reads four scalars. Driving
## `OpportunitySystem.advance` directly runs the SAME code the adapter runs, on
## the same stream, off the same candidate index — `test_the_phase_adapter_is_
## wired_to_the_minute` is what pins the two together, so this rig measures the
## shipped spawner and not a paraphrase of it.
func _run_spawner(sim: CitySim, hours: int) -> Array:
	var out: Array = []
	var minutes := hours * 60
	for i in minutes:
		sim.street.advance(float(4 * (i + 1)) / float(GameClock.TICKS_PER_HOUR), true)
		for event in sim.street.drain_events():
			out.append(event)
	return out


func test_the_spawn_rate_lands_in_the_session_beat() -> void:
	# One game-hour is one real minute at 1x (`SimHost.GAME_MS_PER_REAL_MS` =
	# 60), so this measurement IS the beat the player feels. The design asks for
	# something every 1–3 real minutes on a settled starter city; the band is
	# wide because `data/street.json` is a placeholder the balance agent owns and
	# a tight assertion here would be a gate on a number nobody has fitted yet.
	var total := 0
	var hours := 0
	for seed_value: int in [1337, 4242, 9001]:
		var sim := _sim(seed_value)
		for event in _run_spawner(sim, 120):
			if String(event["type"]) == "opportunity_spawned":
				total += 1
		hours += 120
	assert_true(total > 0, "the layer spawns at all")
	var interval := float(hours) / float(total)
	assert_true(interval >= 1.0 and interval <= 3.0,
			"mean %.2f game-hours between offers is inside the 1–3 real-minute"
			% interval + " beat (doc 06 §2.16)")
	print("  [street] mean interval %.2f gh over %d offers / %d gh"
			% [interval, total, hours])


func test_the_phase_adapter_is_wired_to_the_minute() -> void:
	# The seam the two rigs above depend on, asserted exactly rather than
	# sampled: the adapter's slot, its cadence, and the absolute game-hour it
	# hands the spawner on both paths.
	var sim := _sim()
	var adapter := CitySim.StreetPhaseSystem.new(sim)
	assert_eq(adapter.cadence(), SimSystem.Cadence.EVERY_MINUTE,
			"one evaluation per game-minute")
	assert_eq(adapter.phase(), SimSystem.Phase.INCIDENTS)
	assert_true(String(adapter.system_id()) > "incidents",
			"…and it sorts BEHIND the incident system, so the coverage index it"
			+ " reads is the one this minute already rebuilt")
	assert_eq(adapter.period_ticks(), 4)

	# FINE: `now_h` is `(tick_index + 4) / 240`. Two planted offers straddle it.
	sim.street._live = [
		{"id": 1, "kind": "petty_crime", "tile_x": 10, "tile_y": 10, "side": 0,
			"reward": 100, "spawned_h": 0.0, "expires_h": 484.0 / 240.0 - 0.001},
		{"id": 2, "kind": "petty_crime", "tile_x": 20, "tile_y": 20, "side": 0,
			"reward": 100, "spawned_h": 0.0, "expires_h": 484.0 / 240.0 + 0.001},
	] as Array[Dictionary]
	var ctx := TimeContext.new()
	ctx.tick_index = 480
	adapter.advance_fine(ctx)
	assert_eq(sim.street.live_count(), 1,
			"the offer whose clock ran out at (t+4)/240 is gone; the other stands")
	var events := sim.street.drain_events()
	assert_eq(events.size() >= 1, true, "and it said so")
	assert_eq(String((events[0] as Dictionary)["type"]), "opportunity_expired")
	assert_eq(int((events[0] as Dictionary)["id"]), 1)

	# COARSE: `now_h` is `(tick_index + 240) / 240`, and it says NOTHING.
	sim.street._live = [
		{"id": 3, "kind": "petty_crime", "tile_x": 30, "tile_y": 30, "side": 0,
			"reward": 100, "spawned_h": 0.0, "expires_h": 719.0 / 240.0},
		{"id": 4, "kind": "petty_crime", "tile_x": 40, "tile_y": 40, "side": 0,
			"reward": 100, "spawned_h": 0.0, "expires_h": 721.0 / 240.0},
	] as Array[Dictionary]
	sim.street.drain_events()
	ctx.tick_index = 480
	adapter.advance_coarse(ctx)
	assert_eq(sim.street.live_count(), 1, "the coarse path expires on the hour")
	assert_eq(sim.street.drain_events().size(), 0,
			"…and silently — doc 08 §2.3 rule 9")


# ===========================================================================
# 2. The coverage response
# ===========================================================================

func test_a_city_with_no_police_finds_more_crooks() -> void:
	# The hook, isolated. Both cities are the same city on the same seed and
	# the same stream; the ONLY difference is what `coverage_police` answers,
	# which is precisely the input doc 02 §2.9 publishes and doc 06 §2.16 reads.
	var counts := {}
	for coverage: float in [0.0, 1.0]:
		var sim := _sim()
		sim.street.coverage_police = func(_tile: Vector2i) -> float: return coverage
		var crooks := 0
		var total := 0
		for event in _run_spawner(sim, 240):
			if String(event["type"]) != "opportunity_spawned":
				continue
			total += 1
			if String(event["kind"]) == OpportunitySystem.KIND_PETTY_CRIME:
				crooks += 1
		counts[coverage] = [crooks, total]
	var unpoliced: Array = counts[0.0]
	var covered: Array = counts[1.0]
	assert_true(int(unpoliced[1]) >= 20 and int(covered[1]) >= 20,
			"both arms saw enough offers to compare: %d / %d"
			% [unpoliced[1], covered[1]])
	var share_unpoliced := float(unpoliced[0]) / float(unpoliced[1])
	var share_covered := float(covered[0]) / float(covered[1])
	print("  [street] crook share: unpoliced %.0f%% vs covered %.0f%%"
			% [share_unpoliced * 100.0, share_covered * 100.0])
	assert_true(share_unpoliced > share_covered * 2.0,
			"a city with no police force finds at least twice the share of"
			+ " crooks (%.2f vs %.2f)" % [share_unpoliced, share_covered])
	assert_true(share_unpoliced >= 0.35,
			"…and crime is the dominant kind where nothing is covered: %.2f"
			% share_unpoliced)


func test_the_coverage_knee_is_read_from_the_file_not_the_code() -> void:
	# The weight curve, directly. `data/street.json` authors three points and a
	# knee; this asserts the three points come back and that the segment between
	# them is monotone falling, which is the whole claim the design makes.
	var street := OpportunitySystem.new(
			StarterCityLoader.read_json("res://data/street.json"))
	var row: Dictionary = street._kinds[OpportunitySystem.KIND_PETTY_CRIME]
	var knee := float(row["weak_below"])
	assert_true(knee > 0.0 and knee < 1.0, "the knee is a real coverage value")
	assert_true(absf(OpportunitySystem._coverage_weight(row, 0.0)
			- float(row["weight_at_zero"])) < 1.0e-9,
			"no coverage → the top weight")
	assert_true(absf(OpportunitySystem._coverage_weight(row, knee)
			- float(row["weight_at_threshold"])) < 1.0e-9,
			"at the knee → the threshold weight")
	assert_true(absf(OpportunitySystem._coverage_weight(row, 1.0)
			- float(row["weight_at_full"])) < 1.0e-9,
			"full coverage → the floor weight")
	var previous := 1.0e9
	for step in 21:
		var c := float(step) / 20.0
		var w := OpportunitySystem._coverage_weight(row, c)
		assert_true(w <= previous + 1.0e-9,
				"the weight never rises with coverage (at %.2f)" % c)
		previous = w


# ===========================================================================
# 3. The verb
# ===========================================================================

func test_collecting_pays_once_on_its_own_ledger_line() -> void:
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	var offer: Dictionary = sim.street.live()[0]
	var id := int(offer["id"])
	var reward := int(offer["reward"])
	assert_true(reward > 0, "the offer is worth money")

	var preview := sim.cmd_collect_opportunity(id, true)
	assert_true(bool(preview["ok"]), "preview answers")
	assert_eq(int((preview["payload"] as Dictionary)["reward"]), reward,
			"and quotes the dollars the commit will pay")
	assert_eq(sim.street.live_count(), 1, "a preview takes nothing")

	var balance_before := sim.treasury.balance
	var street_before := int(sim.treasury.lifetime["lifetime_street"])
	var tax_before := int(sim.treasury.lifetime["lifetime_tax"])
	sim.bus.drain()
	var result := sim.cmd_collect_opportunity(id)
	assert_true(bool(result["ok"]), "the tap lands")
	assert_eq(sim.treasury.balance, balance_before + reward,
			"the treasury is up by exactly the quoted bounty")
	assert_eq(int(sim.treasury.lifetime["lifetime_street"]), street_before + reward,
			"…on doc 03 §2.5's own `street` row")
	assert_eq(int(sim.treasury.lifetime["lifetime_tax"]), tax_before,
			"…and not on tax, which the slider owns")
	var collected := _drain(sim, "opportunity_collected")
	assert_eq(collected.size(), 1, "the tap announced itself on the bus")
	assert_eq(int((collected[0] as Dictionary)["reward"]), reward)
	assert_eq(sim.street.live_count(), 0, "and the offer is off the street")

	var again := sim.cmd_collect_opportunity(id)
	assert_false(bool(again["ok"]), "a second tap on the same marker refuses")
	assert_eq(String(again["reason_code"]), "E_UNKNOWN_OPPORTUNITY")


func test_a_marker_that_died_between_the_frame_and_the_finger_refuses() -> void:
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	var id := int((sim.street.live()[0] as Dictionary)["id"])
	# Reaching into `_live` is the point: this is the half-second between the
	# renderer drawing a marker and the spawner's next game-minute, which no
	# amount of advancing can land on reliably.
	sim.street._live[0]["expires_h"] = 0.0
	var balance_before := sim.treasury.balance
	var result := sim.cmd_collect_opportunity(id)
	assert_false(bool(result["ok"]), "a stale marker does not pay")
	assert_eq(String(result["reason_code"]), "E_EXPIRED")
	assert_eq(sim.treasury.balance, balance_before, "and takes no money with it")
	assert_eq(int((result["payload"] as Dictionary)["id"]), id,
			"the refusal still says which marker it was")


func test_an_unknown_id_refuses() -> void:
	var sim := _sim()
	var result := sim.cmd_collect_opportunity(999999)
	assert_false(bool(result["ok"]))
	assert_eq(String(result["reason_code"]), "E_UNKNOWN_OPPORTUNITY")


func test_an_offer_that_nobody_answers_expires_and_says_so() -> void:
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	var offer: Dictionary = sim.street.live()[0]
	var id := int(offer["id"])
	sim.bus.drain()
	# Past the longest lifetime any kind in the file authors.
	sim.advance_hours(5.0)
	var expired := _drain(sim, "opportunity_expired")
	var ids: Array = []
	for event in expired:
		ids.append(int((event as Dictionary)["id"]))
	assert_true(ids.has(id), "the unanswered offer expired: %s" % str(ids))
	assert_eq(sim.street.find(id).size(), 0, "and is off the roster")


func test_the_curriculum_can_count_a_tap() -> void:
	# Doc 09 §2.14's evaluator kind, authorable today. No curriculum ROW uses it
	# yet — gate 21's fitted targets are untouched — so this asserts the kind
	# exists, names the right event and counts one per collection.
	assert_true(GoalSystem.is_known_kind(&"collect_opportunities"),
			"the kind is authorable")
	var rule: Dictionary = GoalSystem.EVENT_KINDS[&"collect_opportunities"]
	assert_eq(String(rule["event"]), "opportunity_collected")
	assert_eq(String(rule["match_field"]), "",
			"an unqualified row counts a collection of any kind")
	var authored := StarterCityLoader.read_json("res://data/goals.json")
	for raw: Variant in authored.get("levels", []):
		for obj: Variant in (raw as Dictionary).get("objectives", []):
			assert_ne(String((obj as Dictionary).get("kind", "")),
					"collect_opportunities",
					"gate 21's curriculum is deliberately untouched this wave")


# ===========================================================================
# 4. Persistence
# ===========================================================================

func test_a_save_taken_mid_crook_restores_the_crook() -> void:
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	var before := sim.street.live()
	var body := sim.canonical_capture()

	var restored := _sim()
	restored.restore_state(body)
	assert_eq(JSON.stringify(restored.street.live()), JSON.stringify(before),
			"same id, same tile, same kerb, same dollars, same expiry")
	assert_eq(restored.state_hash(), sim.state_hash(),
			"and the whole city came back to the bit")

	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(restored.state_hash(), sim.state_hash(),
			"save → load → advance is identical WITH a live offer in the body")


func test_a_v6_body_restores_to_an_empty_street() -> void:
	# The migrator's real claim: a save from the build before this one carries
	# no `street` block at all, and what it meant is "no offers", not "unknown".
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	var body := sim.canonical_capture()
	body.erase("street")
	var migrated := sim.migrate_save_section(body, 6)
	assert_false(migrated.has("street"),
			"v6 → v7 invents no key — restore_state answers this one")
	var restored := _sim()
	restored.restore_state(migrated)
	assert_eq(restored.street.live_count(), 0,
			"a v6 body opens on an empty street, which is what a v6 city had")


## The body with the opportunity layer's OWN three keys removed. If the layer is
## honest, this is byte-for-byte the city the build before it would have written.
func _body_without_the_layer(sim: CitySim) -> String:
	var body := sim.canonical_capture()
	body.erase("street")
	var rng_block: Dictionary = body["rng"]
	rng_block.erase(OpportunitySystem.STREAM_NAME)
	body["rng"] = rng_block
	var treasury_block: Dictionary = body["treasury"]
	var totals: Dictionary = treasury_block["ledger_totals"]
	totals.erase("lifetime_street")
	treasury_block["ledger_totals"] = totals
	body["treasury"] = treasury_block
	return JSON.stringify(body, "", true, true)


func test_the_layer_moves_nothing_outside_its_own_three_keys() -> void:
	# Report 98 RR-77's property, self-contained. Two cities on one seed: one
	# with the spawner LIVE, one with `max_live = 0` so it evaluates nothing and
	# draws nothing. Strip the layer's own three additions — the `street`
	# section, the `street` RNG stream and `ledger_totals.lifetime_street` — and
	# the two bodies must be identical to the byte.
	#
	# This is the assertion that says a system which appears on the street, runs
	# for a game-day and expires cost the rest of the city NOTHING: not a float,
	# not a stream position, not a dollar. The one-time comparison against the
	# Wave-13 published baselines is report 98 RR-77's table; this is the version
	# that keeps holding after the baselines move on.
	var live := _sim()
	var inert := _sim()
	inert.street.max_live = 0
	live.advance_hours(24.0)
	inert.advance_hours(24.0)
	assert_true(live.street.live_count() > 0 or live.state_hash() != inert.state_hash(),
			"the live arm really did run the spawner")
	assert_ne(live.state_hash(), inert.state_hash(),
			"…so the FULL bodies differ, and this test cannot pass vacuously")
	assert_eq(_body_without_the_layer(live), _body_without_the_layer(inert),
			"and with the layer's own three keys removed, the two cities are"
			+ " the same city to the byte")


func test_the_section_rung_moved_with_the_shape() -> void:
	assert_eq(CitySim.SAVE_SECTION_VERSION, 7,
			"the opportunity layer is rung 7 (doc 08 §2.8)")
	var sim := _sim()
	var body := sim.canonical_capture()
	assert_true(body.has("street"), "the body carries the section")
	assert_true((body["rng"] as Dictionary).has(OpportunitySystem.STREAM_NAME),
			"…and the eighth named stream (constitution §5, report 98 RR-77)")
	assert_true((body["treasury"] as Dictionary).has("ledger_totals"))
	assert_true((body["treasury"]["ledger_totals"] as Dictionary).has("lifetime_street"),
			"…and doc 03 §2.5's own ledger row. Those three keys are the WHOLE"
			+ " shape delta — see the byte-identity test above.")


# ===========================================================================
# 5. Offline
# ===========================================================================

func test_nothing_accrues_while_the_player_is_away() -> void:
	var sim := _sim()
	assert_true(_advance_until_live(sim), "something appeared on the street")
	sim.bus.drain()
	var stream_before := sim.rng.stream(OpportunitySystem.STREAM_NAME).state
	sim.advance_coarse_hours(24)
	var events := sim.bus.drain()
	var street_events := 0
	for event in events:
		if String(event.get("type", "")).begins_with("opportunity_"):
			street_events += 1
	assert_eq(street_events, 0,
			"a returning player is told about no bounty they could not have taken")
	assert_eq(sim.street.live_count(), 0,
			"and the street they left is the street they come back to — empty")
	assert_eq(sim.rng.stream(OpportunitySystem.STREAM_NAME).state, stream_before,
			"the `street` stream does not move a single position offline")


func test_the_coarse_path_costs_the_matrix_nothing() -> void:
	# `tests/balance_matrix.gd` runs the COARSE step, so this is the property
	# that keeps `do_nothing` measurable against every table doc 92 ever
	# published: 21 game-days of coarse advance, and the street stream is
	# exactly where it started.
	var sim := _sim()
	var stream_before := sim.rng.stream(OpportunitySystem.STREAM_NAME).state
	sim.advance_coarse_hours(24 * 21)
	assert_eq(sim.rng.stream(OpportunitySystem.STREAM_NAME).state, stream_before,
			"three game-weeks of catch-up draw nothing from `street`")
	assert_eq(sim.street.live_count(), 0)


# ===========================================================================
# 6. The kerb
# ===========================================================================

func test_the_sim_stands_its_actors_on_the_renderer_s_kerb() -> void:
	# `sim/street/` replicates `RoadSurfaceView.classify()`'s kerb test from
	# TileGrid flags because `sim/` may not read `game/` (constitution §3). This
	# is the assertion that keeps the copy honest — a crook must never be
	# standing in a traffic lane.
	var sim := _sim()
	var candidates := sim.street._candidate_tiles()
	assert_true(candidates.size() > 100,
			"the founding city has a street to stand on: %d" % candidates.size())
	var facts := RoadSurfaceView.classify(sim.world.grid, sim.roads.graph)
	var kerb_of: Dictionary = facts["kerb"]

	var mine: Dictionary = {}
	for raw: Variant in candidates:
		var row: Dictionary = raw
		var tile: Vector2i = row["tile"]
		var side := int(row["side"])
		assert_true(kerb_of.has(tile), "%s is a road tile the renderer knows" % str(tile))
		assert_true((int(kerb_of[tile]) & KERB_BITS[side]) != 0,
				"%s side %d is a kerb the renderer draws" % [str(tile), side])
		mine[tile] = true

	# The one deliberate divergence: the renderer kerbs an OFF-MAP neighbour so
	# the road ends in a face; the sim does not, because a bounty may not stand
	# off the world. Removing those sides makes the two sets equal.
	var theirs: Dictionary = {}
	for tile: Vector2i in kerb_of:
		var mask := int(kerb_of[tile])
		for i in 4:
			if (mask & KERB_BITS[i]) == 0:
				continue
			var q: Vector2i = tile + OpportunitySystem.DIRS[i]
			if TileGrid.in_bounds(q.x, q.y):
				theirs[tile] = true
				break
	assert_eq(mine.size(), theirs.size(),
			"the sim's kerb set is the renderer's, minus the off-map faces")
