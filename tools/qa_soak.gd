extends SceneTree
## The long session. A soak harness that plays a **real** `CitySim` for a
## session measured in real hours — mixed speeds, seeded-random player verbs
## every few game-minutes, forced storms, two save/load cycles and an
## app-pause/resume — while watching the four things that only show up over
## hours and never over a unit test:
##
##   1. **Object growth.** `Performance.OBJECT_COUNT` sampled every chunk, and a
##      least-squares slope in objects per game-hour taken across the run. The
##      engine's own end-of-process leak report counts everything ever loaded;
##      what matters to a phone left running is the DELTA while playing, which
##      is what this measures.
##   2. **Step timing drift.** Wall microseconds per fine tick, per chunk, with
##      the first decile compared against the last. A city that gets slower as it
##      grows is expected; a city that gets slower as it *runs* is a leak.
##   3. **Event-bus growth.** Events drained per game-hour, plus the residual
##      `pending_count()` after every drain — a bus that keeps anything after a
##      drain is a bug, and a bus whose per-hour volume climbs without the city
##      growing is a different one.
##   4. **Sanity bounds.** Treasury, population, happiness, stability, building
##      condition and the clock, checked every chunk against the ranges the docs
##      guarantee. NaN anywhere is a failure.
##
## It is a MEASURING instrument (constitution §3): every action goes through a
## `cmd_*`, every number is read off the live sim, it owns no balance constant,
## and nothing in `sim/` may import it. Its randomness is its own
## `RandomNumberGenerator`, never one of doc 01's named streams, so the verb
## stream cannot perturb the simulation's own draws.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/qa_soak.gd -- [options]
##
##   --hours=N            real-hours-equivalent of session      (default 2.0)
##   --seed=N             verb RNG seed                         (default 20250819)
##   --sim-seed=N         the city's own seed                   (default 1337)
##   --speeds=1,2,3       speed multipliers, cycled per segment (default 1,2,3)
##   --segment-min=N      real MINUTES per speed segment        (default 10)
##   --chunk-min=N        game-minutes per measured chunk       (default 5)
##   --verbs-per-chunk=N  average player actions per chunk      (default 1.0)
##   --storm-every-h=N    forced storm cadence, game-hours      (default 8)
##   --saves=N            save/load cycles spread over the run  (default 2)
##   --no-pause           skip the app-pause/resume simulation
##   --max-object-slope=N fail above this many objects/game-hour (default 200)
##   --max-drift=N        fail above this last/first tick-cost ratio (default 3.0)
##   --out=FILE           write the full JSON report
##   --quiet              summary only
##
## Exit code is 0 only when every gate held. Engine-level script errors are not
## visible to GDScript, so a CI wrapper must also fail on them:
##
##   godot --headless --path . -s res://tools/qa_soak.gd -- --hours=2 2>&1 \
##       | tee /tmp/soak.log
##   grep -qE "SCRIPT ERROR|Parse Error|Cannot call method" /tmp/soak.log && exit 1

const DEFAULT_HOURS := 2.0
const DEFAULT_SEED := 20250819
const DEFAULT_SIM_SEED := 1337
const DEFAULT_SPEEDS: Array[int] = [1, 2, 3]
const DEFAULT_SEGMENT_MIN := 10.0
const DEFAULT_CHUNK_MIN := 5
const DEFAULT_VERBS_PER_CHUNK := 1.0
const DEFAULT_STORM_EVERY_H := 8
const DEFAULT_SAVES := 2
const DEFAULT_MAX_OBJECT_SLOPE := 200.0
const DEFAULT_MAX_DRIFT := 3.0

## Doc 01 §2.9: one real second is sixty game-seconds at 1x, and a fine tick is
## fifteen game-seconds — so one real second of play is four ticks per speed
## multiplier. This is the only place the harness converts between the two, and
## it is `SimHost.GAME_MS_PER_REAL_MS / SimHost.TICK_GAME_MS` restated.
const TICKS_PER_REAL_SECOND := 4
const TICKS_PER_GAME_MINUTE := 4
const BLOCK_TILES := 16

## Sanity envelopes. Deliberately WIDE — this harness is not a balance gate
## (docs 92/`tests/test_balance_gates.gd` own those); it is looking for a city
## that has come off its hinges.
const TREASURY_FLOOR := -5_000_000.0
const TREASURY_CEIL := 500_000_000.0
const POPULATION_CEIL := 5_000_000
const HAPPINESS_RANGE := Vector2(0.0, 100.0)
const STABILITY_RANGE := Vector2(0.0, 1.0)

## The verbs the soak plays, with their relative weights. Placement is the
## commonest thing a player does; demolition is the rarest.
const VERB_WEIGHTS := {
	"place_building": 22,
	"place_grid_component": 10,
	"upgrade_building": 14,
	"repair_building": 12,
	"set_priority": 6,
	"set_tax_level": 8,
	"buy_block": 6,
	"start_development": 4,
	"dispatch_unit": 14,
	"demolish_building": 2,
}

## Refusals that are ordinary play, not defects: a player taps things they
## cannot afford and lots they cannot build on all day long.
const EXPECTED_REFUSALS := [
	"E_FUNDS", "E_OCCUPIED", "E_UNSERVED", "E_FOOTPRINT", "E_CITY_LEVEL",
	"E_NOT_OWNED", "E_ALREADY_DEVELOPING", "E_UNKNOWN_BLOCK", "E_MAX_LEVEL",
	"E_UNKNOWN_UNIT", "E_UNKNOWN_INCIDENT", "E_UNIT_UNAVAILABLE", "E_UNREACHABLE",
	"E_STATE", "E_BUSY", "E_UNDER_CONSTRUCTION", "E_NOT_DAMAGED", "E_LOCKED",
	"E_NO_ROAD", "E_BLOCKED", "E_TERRAIN", "E_LEVEL_UNAVAILABLE", "E_RANGE",
	"E_NO_FEEDER", "E_TOO_FAR", "E_CAPACITY", "E_PURCHASABLE", "E_DEV_STATE",
	"E_CONDITION", "E_SAME_LEVEL", "E_UNKNOWN_ARCHETYPE", "E_UNKNOWN_COMPONENT",
	"E_UNKNOWN_BUILDING", "E_DEMOLISH_STATE", "E_NO_CHANGE", "E_COOLDOWN",
	# doc 03's credit ladder refusing discretionary spend while the city is in
	# austerity — ordinary play in a squeezed session, not a defect.
	"E_AUSTERITY", "E_UNKNOWN_PRIORITY", "E_CREDIT", "E_TAX_COOLDOWN",
]

## Archetypes the soak will never bulldoze. A random player who demolishes a
## fire station is not a stress test, it is a different city — and the first
## two-hour run proved it: unguarded demolition razed all 34 buildings by the
## halfway mark and every measurement after that was of an empty map.
const PROTECTED_ARCHETYPES: Array[String] = [
	"police_station", "fire_station", "power_facility", "substation",
	"water_facility", "construction_yard",
]
## Never demolish below this many buildings, for the same reason.
const DEMOLITION_FLOOR := 24


class Options extends RefCounted:
	var hours := DEFAULT_HOURS
	var seed_value := DEFAULT_SEED
	var sim_seed := DEFAULT_SIM_SEED
	var speeds: Array[int] = DEFAULT_SPEEDS.duplicate()
	var segment_min := DEFAULT_SEGMENT_MIN
	var chunk_min := DEFAULT_CHUNK_MIN
	var verbs_per_chunk := DEFAULT_VERBS_PER_CHUNK
	var storm_every_h := DEFAULT_STORM_EVERY_H
	var saves := DEFAULT_SAVES
	var pause := true
	var max_object_slope := DEFAULT_MAX_OBJECT_SLOPE
	var max_drift := DEFAULT_MAX_DRIFT
	var out := ""
	var quiet := false
	var errors: Array[String] = []

	static func parse(args: PackedStringArray) -> Options:
		var o := Options.new()
		for raw in args:
			var arg := String(raw)
			if arg.begins_with("--hours="):
				o.hours = maxf(0.01, float(arg.trim_prefix("--hours=")))
			elif arg.begins_with("--seed="):
				o.seed_value = int(arg.trim_prefix("--seed="))
			elif arg.begins_with("--sim-seed="):
				o.sim_seed = int(arg.trim_prefix("--sim-seed="))
			elif arg.begins_with("--speeds="):
				o.speeds.clear()
				for part in arg.trim_prefix("--speeds=").split(","):
					var value := int(part)
					if value > 0:
						o.speeds.append(value)
				if o.speeds.is_empty():
					o.errors.append("--speeds needs at least one positive multiplier")
			elif arg.begins_with("--segment-min="):
				o.segment_min = maxf(0.1, float(arg.trim_prefix("--segment-min=")))
			elif arg.begins_with("--chunk-min="):
				o.chunk_min = maxi(1, int(arg.trim_prefix("--chunk-min=")))
			elif arg.begins_with("--verbs-per-chunk="):
				o.verbs_per_chunk = maxf(0.0, float(arg.trim_prefix("--verbs-per-chunk=")))
			elif arg.begins_with("--storm-every-h="):
				o.storm_every_h = maxi(0, int(arg.trim_prefix("--storm-every-h=")))
			elif arg.begins_with("--saves="):
				o.saves = maxi(0, int(arg.trim_prefix("--saves=")))
			elif arg == "--no-pause":
				o.pause = false
			elif arg.begins_with("--max-object-slope="):
				o.max_object_slope = float(arg.trim_prefix("--max-object-slope="))
			elif arg.begins_with("--max-drift="):
				o.max_drift = float(arg.trim_prefix("--max-drift="))
			elif arg.begins_with("--out="):
				o.out = arg.trim_prefix("--out=")
			elif arg == "--quiet":
				o.quiet = true
			else:
				o.errors.append("unknown option " + arg)
		return o


var _opts: Options
var _sim: CitySim
var _rng := RandomNumberGenerator.new()
var _samples: Array[Dictionary] = []
var _verb_counts: Dictionary = {}      # verb -> {ok, refused, codes{}}
var _failures: Array[String] = []
var _notes: Array[String] = []
var _events_by_type: Dictionary = {}
var _pose_rows: int = 0
var _storms := 0
var _save_cycles: Array[Dictionary] = []
var _pause_cycles: Array[Dictionary] = []
var _retained_per_reload: Array[int] = []
var _block_cursor := 0
var _archetypes: Array[String] = []
var _grid_kinds: Array[String] = []
var _priority_classes: Array[String] = []


func _initialize() -> void:
	_opts = Options.parse(OS.get_cmdline_user_args())
	if not _opts.errors.is_empty():
		for message in _opts.errors:
			printerr("qa_soak: " + message)
		quit(2)
		return

	_rng.seed = _opts.seed_value
	_sim = CitySim.boot_from_files(_opts.sim_seed)
	if not _sim.boot_errors.is_empty():
		_fail("boot errors: %s" % str(_sim.boot_errors))
	_archetypes = _sorted_strings(_sim.catalog.archetypes())
	_grid_kinds = _placeable_grid_kinds()
	_priority_classes = _sorted_strings(
			(_sim.grid_rules.get("priority", {}) as Dictionary).get("classes", []))

	var plan := _plan()
	if not _opts.quiet:
		print("qa_soak: %.2f real-hours at speeds %s → %d chunks, %.1f game-hours"
				% [_opts.hours, str(_opts.speeds), int(plan["chunks"]),
						float(plan["game_hours"])])
		print("         seed %d (verbs) / %d (city), %d save cycles, pause=%s"
				% [_opts.seed_value, _opts.sim_seed, _opts.saves, str(_opts.pause)])

	_run(plan)
	var report := _report(plan)
	_print_report(report)
	if _opts.out != "":
		_write_json(_opts.out, report)
	quit(1 if not _failures.is_empty() else 0)


# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

## Turns "N real hours at these speeds" into a chunk schedule. A chunk is a
## fixed number of GAME minutes, so a 3x segment simply spends fewer real
## seconds per chunk — which is exactly what the accumulator in `SimHost` does.
func _plan() -> Dictionary:
	return plan_for(_opts)


## Static so `tests/test_qa_soak.gd` can assert the schedule without booting a
## city: the conversion from "N real hours at these speeds" to a chunk list is
## the one piece of arithmetic in this harness that a reader has to trust.
static func plan_for(o: Options) -> Dictionary:
	var real_seconds := o.hours * 3600.0
	var segment_s := o.segment_min * 60.0
	var segments := maxi(1, int(ceil(real_seconds / segment_s)))
	var chunks: Array[Dictionary] = []
	var game_minutes := 0.0
	var remaining := real_seconds
	for index in segments:
		var speed: int = o.speeds[index % o.speeds.size()]
		var span_s := minf(segment_s, remaining)
		remaining -= span_s
		# real seconds → game minutes: one real second is sixty game-seconds at
		# 1x (doc 01 §2.9 / `SimHost.GAME_MS_PER_REAL_MS`), i.e. one game-minute.
		var segment_game_min := span_s * float(speed)
		var n := maxi(1, int(round(segment_game_min / float(o.chunk_min))))
		for c in n:
			chunks.append({"speed": speed, "minutes": o.chunk_min,
					"real_s": float(o.chunk_min) / float(speed)})
			game_minutes += float(o.chunk_min)
		if remaining <= 0.0:
			break
	return {"chunks": chunks.size(), "chunk_list": chunks,
			"game_hours": game_minutes / 60.0, "real_seconds": real_seconds}


func _run(plan: Dictionary) -> void:
	var chunks: Array = plan["chunk_list"]
	var save_at: Array[int] = []
	for i in _opts.saves:
		save_at.append(int(float(chunks.size()) * float(i + 1) / float(_opts.saves + 1)))
	var pause_at := int(chunks.size() * 0.5) if _opts.pause else -1
	var next_storm_h := _opts.storm_every_h

	for index in chunks.size():
		var chunk: Dictionary = chunks[index]
		_play_verbs(int(chunk["speed"]))
		var ticks := int(chunk["minutes"]) * TICKS_PER_GAME_MINUTE
		var t0 := Time.get_ticks_usec()
		_sim.scheduler.advance_fine_n(ticks)
		var usec := Time.get_ticks_usec() - t0
		var drained := _sim.bus.drain()
		_count_events(drained)
		_sample(index, chunk, ticks, usec, drained.size())

		var game_hour := _sim.clock.sim_time_minutes() / 60
		if _opts.storm_every_h > 0 and game_hour >= next_storm_h:
			_force_storm()
			next_storm_h = game_hour + _opts.storm_every_h
		if save_at.has(index):
			_save_cycle(index)
		if index == pause_at:
			_pause_cycle(index)
	# One last drain so the residual check below is about the bus, not the loop.
	_count_events(_sim.bus.drain())


# ---------------------------------------------------------------------------
# Player verbs — seeded, weighted, and every one of them a real command
# ---------------------------------------------------------------------------

func _play_verbs(speed: int) -> void:
	# A player at 3x is not issuing three times the commands; if anything they
	# are watching. One draw per chunk plus a coin flip is close enough to the
	# tapping rate a session shows, and it keeps the stream seed-stable.
	var n := int(_opts.verbs_per_chunk)
	if _rng.randf() < _opts.verbs_per_chunk - float(n):
		n += 1
	if speed >= 3 and n > 1:
		n -= 1
	for i in n:
		_play_one(_pick_verb())


func _pick_verb() -> String:
	var keys := _sorted_strings(VERB_WEIGHTS.keys())
	var total := 0
	for key: String in keys:
		total += int(VERB_WEIGHTS[key])
	var roll := _rng.randi_range(1, total)
	for key: String in keys:
		roll -= int(VERB_WEIGHTS[key])
		if roll <= 0:
			return key
	return keys[0]


## A player who is overdrawn raises tax before they buy anything else — the one
## piece of judgement the soak's random player is given, because without it the
## session spends its second hour bankrupt and measures a frozen city.
func _solvency_reflex() -> bool:
	if _sim.treasury.balance >= 0.0:
		return false
	var level := _sim.tax_level()
	if level + 1 >= _sim.tax_level_count():
		return false
	var result := _sim.cmd_set_tax_level(level + 1)
	_record_verb("set_tax_level", result)
	return bool(result["ok"])


func _play_one(verb: String) -> void:
	if _solvency_reflex():
		return
	var result: Dictionary = {}
	match verb:
		"place_building":
			var archetype := _archetypes[_rng.randi_range(0, _archetypes.size() - 1)]
			var foot: Array = _sim.catalog.stats(archetype, 1).get("footprint", [1, 1])
			var size := Vector2i(int(foot[0]), int(foot[1]))
			var tile := _served_site(size)
			if tile.x < 0:
				return _skip(verb, "no served site")
			result = _sim.cmd_place_building(archetype, tile)
		"place_grid_component":
			if _grid_kinds.is_empty():
				return _skip(verb, "no placeable grid kinds")
			var kind := _grid_kinds[_rng.randi_range(0, _grid_kinds.size() - 1)]
			var tile := _unserved_site()
			if tile.x < 0:
				return _skip(verb, "no unserved site")
			result = _sim.cmd_place_grid_component(kind, tile, 1)
		"upgrade_building":
			var id := _random_building(&"active")
			if id == "":
				return _skip(verb, "no active building")
			result = _sim.cmd_upgrade_building(id)
		"repair_building":
			var id := _worst_condition_building()
			if id == "":
				return _skip(verb, "nothing to repair")
			result = _sim.cmd_repair_building(id)
		"demolish_building":
			var id := _demolishable_building()
			if id == "":
				return _skip(verb, "nothing safe to demolish")
			result = _sim.cmd_demolish_building(id)
		"set_priority":
			var id := _random_building(&"")
			if id == "":
				return _skip(verb, "no building")
			if _priority_classes.is_empty():
				return _skip(verb, "no priority classes authored")
			result = _sim.cmd_set_priority(id,
					_priority_classes[_rng.randi_range(0, _priority_classes.size() - 1)])
		"set_tax_level":
			var level := _rng.randi_range(0, maxi(0, _sim.tax_level_count() - 1))
			result = _sim.cmd_set_tax_level(level)
		"buy_block":
			var block := _purchasable_block()
			if block == "":
				return _skip(verb, "nothing purchasable")
			result = _sim.cmd_buy_block(block)
		"start_development":
			var block := _undeveloped_block()
			if block == "":
				return _skip(verb, "nothing to develop")
			result = _sim.cmd_start_development(block)
		"dispatch_unit":
			var pair := _dispatch_pair()
			if pair.is_empty():
				return _skip(verb, "no incident or no free unit")
			result = _sim.cmd_dispatch_unit(int(pair["unit"]), int(pair["incident"]))
		_:
			return
	_record_verb(verb, result)


func _skip(verb: String, reason: String) -> void:
	var row := _verb_row(verb)
	row["skipped"] = int(row["skipped"]) + 1
	var reasons: Dictionary = row["skip_reasons"]
	reasons[reason] = int(reasons.get(reason, 0)) + 1


func _verb_row(verb: String) -> Dictionary:
	if not _verb_counts.has(verb):
		_verb_counts[verb] = {"ok": 0, "refused": 0, "skipped": 0,
				"codes": {}, "skip_reasons": {}}
	return _verb_counts[verb]


func _record_verb(verb: String, result: Dictionary) -> void:
	var row := _verb_row(verb)
	if result.is_empty():
		_fail("%s returned nothing — every cmd_* answers {ok, reason_code, payload}"
				% verb)
		return
	if not result.has("ok"):
		_fail("%s answered without an `ok` key: %s" % [verb, str(result)])
		return
	if bool(result["ok"]):
		row["ok"] = int(row["ok"]) + 1
		return
	row["refused"] = int(row["refused"]) + 1
	var code := String(result.get("reason_code", ""))
	var codes: Dictionary = row["codes"]
	codes[code] = int(codes.get(code, 0)) + 1
	if code == "":
		_fail("%s refused with an empty reason_code: %s" % [verb, str(result)])
	elif not EXPECTED_REFUSALS.has(code):
		# Not a failure — a new refusal code is normal engineering — but the
		# soak is the place it should first become visible.
		_note("%s answered an unlisted refusal code %s" % [verb, code])


# --------------------------------------------------------------- site search

## A placeable, served footprint in an owned + READY block, starting the scan at
## a seeded offset so the soak spreads out over the city instead of filling one
## corner. Bounded: at most `_ready_blocks().size()` blocks are probed.
func _served_site(size: Vector2i) -> Vector2i:
	return _site(size, true)


func _unserved_site() -> Vector2i:
	return _site(Vector2i.ONE, false)


func _site(size: Vector2i, served: bool) -> Vector2i:
	var blocks := _ready_blocks()
	if blocks.is_empty():
		return Vector2i(-1, -1)
	_block_cursor = _rng.randi_range(0, blocks.size() - 1)
	for offset in blocks.size():
		var block: LandBlock = _sim.world.block(
				blocks[(_block_cursor + offset) % blocks.size()])
		var x0: int = block.grid.x * BLOCK_TILES
		var z0: int = block.grid.y * BLOCK_TILES
		for z in range(z0, z0 + BLOCK_TILES - size.y + 1):
			for x in range(x0, x0 + BLOCK_TILES - size.x + 1):
				var origin := Vector2i(x, z)
				if not _sim.world.grid.can_place(origin, size):
					continue
				if _sim.grid.would_serve(origin) == served:
					return origin
	return Vector2i(-1, -1)


func _ready_blocks() -> Array[String]:
	var out: Array[String] = []
	for id: Variant in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(String(id))
		if block != null and block.is_ready():
			out.append(String(id))
	return out


func _purchasable_block() -> String:
	var candidates: Array[String] = []
	for id: Variant in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(String(id))
		if block != null and block.ownership_state == &"PURCHASABLE":
			candidates.append(String(id))
	if candidates.is_empty():
		return ""
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


func _undeveloped_block() -> String:
	var candidates: Array[String] = []
	for id: Variant in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(String(id))
		if block != null and block.is_owned() and not block.is_ready():
			candidates.append(String(id))
	if candidates.is_empty():
		return ""
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


func _building_ids() -> Array[String]:
	var out: Array[String] = []
	for id: Variant in _sim.buildings.keys():
		out.append(String(id))
	out.sort()
	return out


func _random_building(state: StringName) -> String:
	var ids := _building_ids()
	var pool: Array[String] = []
	for id: String in ids:
		var b: Building = _sim.buildings[id]
		if state == &"" or b.state == state:
			pool.append(id)
	if pool.is_empty():
		return ""
	return pool[_rng.randi_range(0, pool.size() - 1)]


## Demolition, with the two guards a player applies without thinking: not the
## stations, and not the last of the city.
func _demolishable_building() -> String:
	var ids := _building_ids()
	if ids.size() <= DEMOLITION_FLOOR:
		return ""
	var pool: Array[String] = []
	for id: String in ids:
		var b: Building = _sim.buildings[id]
		if not PROTECTED_ARCHETYPES.has(b.archetype):
			pool.append(id)
	if pool.is_empty():
		return ""
	return pool[_rng.randi_range(0, pool.size() - 1)]


## Repair is not a random tap: a player repairs the thing that is broken. The
## worst-condition building is the honest choice and keeps the verb useful.
func _worst_condition_building() -> String:
	var worst := ""
	var worst_condition := 2.0
	for id: String in _building_ids():
		var b: Building = _sim.buildings[id]
		if b.condition < worst_condition:
			worst_condition = b.condition
			worst = id
	return worst if worst_condition < 0.999 else ""


func _dispatch_pair() -> Dictionary:
	var rows: Array = _sim.incidents.snapshot()
	if rows.is_empty():
		return {}
	var incident_id := int((rows[_rng.randi_range(0, rows.size() - 1)] as Dictionary)["id"])
	var free: Array[int] = []
	for uid: Variant in _sim.incidents.fleet.unit_ids():
		var unit: Vehicle = _sim.incidents.fleet.unit(int(uid))
		if unit != null and unit.is_dispatchable_now():
			free.append(int(uid))
	if free.is_empty():
		return {}
	return {"unit": free[_rng.randi_range(0, free.size() - 1)],
			"incident": incident_id}


func _placeable_grid_kinds() -> Array[String]:
	var out: Array[String] = []
	var raw: Dictionary = StarterCityLoader.read_json("res://data/grid_components.json")
	var placeable: Variant = raw.get("placeable", {})
	if placeable is Dictionary:
		for key: Variant in (placeable as Dictionary):
			out.append(String(key))
	out.sort()
	return out


# ---------------------------------------------------------------------------
# Forced weather, save cycles, app pause
# ---------------------------------------------------------------------------

## Doc 07 §2.7.1's director hook, used the way the director uses it. The storm is
## put 30 game-minutes out so the lead-in is honest.
func _force_storm() -> void:
	if _sim.weather == null:
		return
	var now_min := _sim.clock.sim_time_minutes()
	_sim.weather.inject_storm(now_min + 30, _rng.randi_range(45, 150),
			_rng.randf_range(0.55, 0.95), 900_000 + _storms)
	_storms += 1


## The law: save → load → advance is EXACT. Verified mid-session rather than
## from a clean boot, because the interesting state (a half-built queue, a crew
## on scene, a storm in the timeline) only exists in the middle of a run. The
## restored city becomes the one the soak keeps playing, so any drift the reload
## introduces poisons everything after it — which is the point.
func _save_cycle(index: int) -> void:
	var objects_before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var before_hash := _sim.state_hash()
	var service := SaveService.new()
	service.base_dir = "user://qa_soak"
	var meta := service.save_slot(_sim, 1)
	var wrote := not meta.is_empty()
	if not wrote:
		_fail("save cycle %d: SaveService refused (%s)" % [index, service.last_error])
		service.free()
		return
	var restored := CitySim.boot_from_files(_opts.sim_seed)
	if not service.load_slot(restored, 1):
		_fail("save cycle %d: load failed (%s)" % [index, service.last_error])
		service.free()
		return
	var after_hash := restored.state_hash()
	var identical := before_hash == after_hash
	if not identical:
		_fail("save cycle %d: state_hash changed across save/load (%s → %s)"
				% [index, before_hash.substr(0, 12), after_hash.substr(0, 12)])
	# ... and the advance identity, which a hash of the restored state cannot
	# prove on its own: both cities take the same hour and must still agree.
	_sim.advance_hours(1.0)
	restored.advance_hours(1.0)
	_sim.bus.drain()
	restored.bus.drain()
	var advanced_a := _sim.state_hash()
	var advanced_b := restored.state_hash()
	if advanced_a != advanced_b:
		_fail("save cycle %d: the reloaded city diverged after one hour (%s vs %s)"
				% [index, advanced_a.substr(0, 12), advanced_b.substr(0, 12)])
	# The reload boots a SECOND CitySim and then drops the first. Whether the
	# first is actually reclaimed is the single most useful number this harness
	# takes: `sim/` is RefCounted-only, and Godot does not collect cycles.
	var retained := int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objects_before
	_retained_per_reload.append(retained)
	_save_cycles.append({
		"chunk": index,
		"game_minute": _sim.clock.sim_time_minutes(),
		"bytes": _slot_bytes(service, 1),
		"objects_retained": retained,
		"hash_before": before_hash,
		"hash_after": after_hash,
		"identical": identical,
		"advance_identical": advanced_a == advanced_b,
	})
	# Carry on inside the RELOADED city.
	_sim = restored
	service.delete_slot(1)
	service.free()


func _slot_bytes(service: SaveService, slot: int) -> int:
	var path := service.slot_path(slot)
	if not FileAccess.file_exists(path):
		return 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file = null
	return size


## App pause → resume, twice: a 30 s blur (inside doc 01's two-minute grace, so
## nothing at all is credited) and 45 real minutes away (the coarse catch-up).
##
## Driven through `CatchUpPlanner.plan()` — head-align, coarse hours, mid-fine,
## fine tail, residual carry — because that is the schedule doc 01 §2.10
## specifies and `TickScheduler.advance_coarse_n` asserts on.
##
## **The divergence this harness was written to expose is closed** (2026-08-19,
## Wave 7, doc 91 D-1): `game/main.gd._on_app_resumed` now plans the resume
## through the same call and walks the same segments, so the soak and the shell
## take the identical path.
##
## **What the `_note()` below now checks (rewritten Wave 9, 2026-08-20).** It
## used to describe the pre-`CatchUpPlanner` shell and claim the shell resumed on
## an unaligned tick — a sentence that had been false since D-1 closed, so an
## instrument whose whole job is to report surprises was reporting a stale one on
## every off-hour pause. The condition it fires on is still worth keeping, but it
## means something else: an off-hour pause is the case where the planner has to
## do real work — a head-align fine segment, then coarse hours, then a fine tail,
## then a residual carry — and it is therefore the case where a resume bug would
## show. The note now records that this cycle exercised that path, with the
## residual it started from, so a reader of the report can tell an aligned cycle
## (which proves almost nothing) from an unaligned one (which proves the ladder).
func _pause_cycle(index: int) -> void:
	var before := {"treasury": _sim.treasury.balance,
			"population": _sim.population.city_population,
			"day": _sim.clock.day_index()}
	if _sim.clock.tick_index % GameClock.TICKS_PER_HOUR != 0:
		_note("resume path: cycle paused %d/%d ticks into a game-hour, so this "
				% [_sim.clock.tick_index % GameClock.TICKS_PER_HOUR,
						GameClock.TICKS_PER_HOUR]
				+ "cycle exercised CatchUpPlanner's full ladder — head-align, "
				+ "coarse hours, fine tail, residual carry — which is the same "
				+ "call game/main.gd._on_app_resumed makes (doc 91 D-1, closed "
				+ "2026-08-19). An hour-aligned pause would skip the head-align.")

	var rows: Array[Dictionary] = []
	for elapsed_real_s: float in [30.0, 45.0 * 60.0]:
		var plan := CatchUpPlanner.plan(int(elapsed_real_s * 1000.0),
				_sim.clock.residual_game_ms, _sim.clock.tick_index)
		var t0 := Time.get_ticks_usec()
		var coarse_hours := 0
		for segment: Dictionary in (plan["segments"] as Array):
			var count := int(segment["count"])
			if String(segment["kind"]) == "coarse":
				coarse_hours += count
				_sim.advance_coarse_hours(count)
			else:
				_sim.scheduler.advance_fine_n(count)
		_sim.clock.residual_game_ms = int(plan["new_residual_game_ms"])
		var usec := Time.get_ticks_usec() - t0
		var drained := _sim.bus.drain()
		_count_events(drained)
		rows.append({
			"chunk": index,
			"elapsed_real_s": elapsed_real_s,
			"credited_real_ms": int(plan["credited_real_ms"]),
			"capped": bool(plan["capped"]),
			"total_ticks": int(plan["total_ticks"]),
			"coarse_hours": coarse_hours,
			"usec": usec,
			"events": drained.size(),
		})
		if int(plan["total_ticks"]) != CatchUpPlanner.segments_total_ticks(plan):
			_fail("pause cycle %d: the plan's segments do not sum to its tick total"
					% index)
		_sanity(-1)

	var after := {"treasury": _sim.treasury.balance,
			"population": _sim.population.city_population,
			"day": _sim.clock.day_index()}
	if int(after["day"]) < int(before["day"]):
		_fail("pause cycle %d: the clock went backwards" % index)
	for row: Dictionary in rows:
		row["before"] = before
		row["after"] = after
		_pause_cycles.append(row)


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

func _sample(index: int, chunk: Dictionary, ticks: int, usec: int, events: int) -> void:
	var residual := _sim.bus.pending_count()
	if residual != 0:
		_fail("chunk %d: %d events left on the bus after drain()" % [index, residual])
	var row := {
		"chunk": index,
		"speed": int(chunk["speed"]),
		"game_minute": _sim.clock.sim_time_minutes(),
		"game_hour": float(_sim.clock.sim_time_minutes()) / 60.0,
		"ticks": ticks,
		"usec": usec,
		"usec_per_tick": float(usec) / float(maxi(1, ticks)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"events": events,
		"buildings": _sim.buildings.size(),
		"components": _sim.grid.component_ids().size(),
		"incidents": _sim.incidents.active_count(),
		"treasury": _sim.treasury.balance,
		"population": _sim.population.city_population,
		"happiness": _sim.happiness.happiness,
		"stability": _sim.districts.city_stability,
		"city_level": _sim.progression.city_level,
	}
	_samples.append(row)
	_sanity(index)


## Every bound the docs actually guarantee, checked every chunk. A NaN is the
## one that matters most: it survives a save, spreads through every average, and
## is invisible until a number renders as `nan` on a phone.
func _sanity(index: int) -> void:
	var where := "chunk %d" % index if index >= 0 else "pause cycle"
	var treasury := float(_sim.treasury.balance)
	var happiness := _sim.happiness.happiness
	var stability := _sim.districts.city_stability
	for pair: Array in [["treasury", treasury], ["happiness", happiness],
			["stability", stability]]:
		if is_nan(float(pair[1])) or is_inf(float(pair[1])):
			_fail("%s: %s is not a finite number (%s)"
					% [where, str(pair[0]), str(pair[1])])
	if treasury < TREASURY_FLOOR or treasury > TREASURY_CEIL:
		_fail("%s: treasury %s outside [%s, %s]"
				% [where, str(treasury), str(TREASURY_FLOOR), str(TREASURY_CEIL)])
	var population := _sim.population.city_population
	if population < 0 or population > POPULATION_CEIL:
		_fail("%s: population %d outside [0, %d]" % [where, population, POPULATION_CEIL])
	if happiness < HAPPINESS_RANGE.x - 0.001 or happiness > HAPPINESS_RANGE.y + 0.001:
		_fail("%s: happiness %f outside [%.0f, %.0f]"
				% [where, happiness, HAPPINESS_RANGE.x, HAPPINESS_RANGE.y])
	if stability < STABILITY_RANGE.x - 0.001 or stability > STABILITY_RANGE.y + 0.001:
		_fail("%s: stability %f outside [%.0f, %.0f]"
				% [where, stability, STABILITY_RANGE.x, STABILITY_RANGE.y])
	for id: String in _building_ids():
		var b: Building = _sim.buildings[id]
		if is_nan(b.condition) or b.condition < -0.001 or b.condition > 1.001:
			_fail("%s: %s condition %s outside [0, 1]" % [where, id, str(b.condition)])
			break


## Doc 91 D-10: a packed event is one event on the bus but many RECORDS, and a
## before/after comparison that counted only events would flatter the diet by
## construction. `_pose_rows` is the count of vehicle poses carried inside the
## packed `traffic_snapshot` events — i.e. exactly the number of `vehicle_state`
## events the same run would have put on the bus before the diet.
func _count_events(batch: Array) -> void:
	for event: Variant in batch:
		var record: Dictionary = event
		var kind := String(record.get("type", ""))
		_events_by_type[kind] = int(_events_by_type.get(kind, 0)) + 1
		if kind == String(TrafficSnapshot.VEHICLE_EVENT):
			_pose_rows += TrafficSnapshot.vehicle_count(record)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

func _report(plan: Dictionary) -> Dictionary:
	var objects := _series("objects")
	var hours := _series("game_hour")
	var cost := _series("usec_per_tick")
	var object_slope := _slope(hours, objects)
	# The same slope with each reload's retention subtracted from every sample
	# after it. A save/load cycle is a STEP, not a leak rate; charging it to the
	# slope would either hide a real drip or invent one.
	var retained_total := 0
	for value: int in _retained_per_reload:
		retained_total += maxi(0, value)
	var steady := _without_reload_steps(objects)
	var steady_slope := _slope(hours, steady)
	var drift := _decile_ratio(cost)
	var events_total := 0
	for key: Variant in _events_by_type:
		events_total += int(_events_by_type[key])

	if _samples.size() >= 8:
		if absf(steady_slope) > _opts.max_object_slope:
			_fail("ObjectDB slope %.1f objects/game-hour exceeds %.1f (save-cycle "
					% [steady_slope, _opts.max_object_slope]
					+ "retention already excluded)")
		if drift > _opts.max_drift:
			_fail("step cost drifted %.2fx from the first decile to the last (limit %.2f)"
					% [drift, _opts.max_drift])

	var first: Dictionary = _samples[0] if not _samples.is_empty() else {}
	var last: Dictionary = _samples[-1] if not _samples.is_empty() else {}
	# Game-hours actually elapsed on the clock, not the ones the plan asked for:
	# the pause cycles credit dozens of hours the chunk schedule never counted,
	# and a per-hour event rate that ignores them is a lie.
	var elapsed_game_hours := maxf(0.001,
			(float(last.get("game_minute", 0)) - float(first.get("game_minute", 0))) / 60.0)
	return {
		"schema": 1,
		"options": {
			"hours": _opts.hours, "seed": _opts.seed_value, "sim_seed": _opts.sim_seed,
			"speeds": _opts.speeds, "chunk_min": _opts.chunk_min,
			"saves": _opts.saves, "pause": _opts.pause,
			"storm_every_h": _opts.storm_every_h,
		},
		"plan": {"chunks": plan["chunks"], "game_hours": plan["game_hours"],
				"real_seconds": plan["real_seconds"],
				"elapsed_game_hours": elapsed_game_hours},
		"objects": {
			"first": int(first.get("objects", 0)),
			"last": int(last.get("objects", 0)),
			"min": _min_of(objects), "max": _max_of(objects),
			"slope_per_game_hour": object_slope,
			"steady_slope_per_game_hour": steady_slope,
			"retained_per_reload": _retained_per_reload,
			"retained_total": retained_total,
		},
		"timing": {
			"usec_per_tick_mean": _mean(cost),
			"usec_per_tick_p95": _percentile(cost, 0.95),
			"usec_per_tick_max": _max_of(cost),
			"first_decile_mean": _decile_mean(cost, true),
			"last_decile_mean": _decile_mean(cost, false),
			"drift_ratio": drift,
		},
		"events": {
			"total": events_total,
			"per_game_hour": float(events_total) / elapsed_game_hours,
			# The bus diet's before/after, measured rather than argued.
			"pose_rows": _pose_rows,
			"total_before_diet": events_total - int(
					_events_by_type.get(String(TrafficSnapshot.VEHICLE_EVENT), 0)) + _pose_rows,
			"by_type": _events_by_type.duplicate(),
			"top": _top_events(12),
		},
		"city": {
			"buildings_first": int(first.get("buildings", 0)),
			"buildings_last": int(last.get("buildings", 0)),
			"population_first": int(first.get("population", 0)),
			"population_last": int(last.get("population", 0)),
			"treasury_first": float(first.get("treasury", 0.0)),
			"treasury_last": float(last.get("treasury", 0.0)),
			"treasury_min": _min_of(_series("treasury")),
			"treasury_max": _max_of(_series("treasury")),
			"happiness_min": _min_of(_series("happiness")),
			"happiness_last": float(last.get("happiness", 0.0)),
			"stability_min": _min_of(_series("stability")),
			"city_level_last": int(last.get("city_level", 0)),
			"incidents_max": _max_of(_series("incidents")),
		},
		"verbs": _verb_counts,
		"storms": _storms,
		"save_cycles": _save_cycles,
		"pause_cycles": _pause_cycles,
		"notes": _notes,
		"failures": _failures,
		"samples": _samples,
	}


func _print_report(report: Dictionary) -> void:
	var objects: Dictionary = report["objects"]
	var timing: Dictionary = report["timing"]
	var events: Dictionary = report["events"]
	var city: Dictionary = report["city"]
	print("")
	print("================================================================")
	var plan_block: Dictionary = report["plan"]
	print("qa_soak — %.2f real-hours played, %.1f game-hours advanced (%.1f on the "
			% [_opts.hours, float(plan_block["elapsed_game_hours"]),
					float(plan_block["game_hours"])]
			+ "chunk schedule, the rest offline), %d chunks"
			% int(plan_block["chunks"]))
	print("----------------------------------------------------------------")
	print("ObjectDB   first %-7d last %-7d  min %-7d max %-7d"
			% [int(objects["first"]), int(objects["last"]),
					int(float(objects["min"])), int(float(objects["max"]))])
	print("           slope %+0.2f raw, %+0.2f steady objects / game-hour  (gate ±%.0f)"
			% [float(objects["slope_per_game_hour"]),
					float(objects["steady_slope_per_game_hour"]), _opts.max_object_slope])
	if not _retained_per_reload.is_empty():
		print("           %d objects retained per save/load cycle %s — a replaced "
				% [int(objects["retained_total"]) / maxi(1, _retained_per_reload.size()),
						str(_retained_per_reload)]
				+ "CitySim is never reclaimed")
	print("Step cost  mean %.1f  p95 %.1f  max %.1f usec/tick"
			% [float(timing["usec_per_tick_mean"]), float(timing["usec_per_tick_p95"]),
					float(timing["usec_per_tick_max"])])
	print("           first decile %.1f → last decile %.1f  = %.2fx  (gate %.2fx)"
			% [float(timing["first_decile_mean"]), float(timing["last_decile_mean"]),
					float(timing["drift_ratio"]), _opts.max_drift])
	print("Bus        %d events, %.1f / game-hour, 0 residual after every drain"
			% [int(events["total"]), float(events["per_game_hour"])])
	var rows := int(events.get("pose_rows", 0))
	if rows > 0:
		var before := int(events["total_before_diet"])
		print("Bus diet   %d packed poses in %d events; the pre-diet bus would have"
				% [rows, int(_events_by_type.get(String(TrafficSnapshot.VEHICLE_EVENT), 0))]
				+ " carried %d events (%.1fx)" % [before,
						float(before) / maxf(1.0, float(int(events["total"])))])
	print("City       buildings %d→%d   pop %d→%d   level %d"
			% [int(city["buildings_first"]), int(city["buildings_last"]),
					int(city["population_first"]), int(city["population_last"]),
					int(city["city_level_last"])])
	print("           treasury %s → %s   (min %s, max %s)"
			% [_money(float(city["treasury_first"])), _money(float(city["treasury_last"])),
					_money(float(city["treasury_min"])), _money(float(city["treasury_max"]))])
	print("           happiness min %.1f last %.1f   stability min %.3f   incidents max %d"
			% [float(city["happiness_min"]), float(city["happiness_last"]),
					float(city["stability_min"]), int(float(city["incidents_max"]))])
	print("Storms     %d forced   incidents created %d, resolved %d"
			% [_storms, int(_events_by_type.get("incident_created", 0)),
					int(_events_by_type.get("incident_resolved", 0))])
	var top: Array[String] = []
	for kind: String in _sorted_strings((events["top"] as Dictionary).keys()):
		top.append("%s×%d" % [kind, int((events["top"] as Dictionary)[kind])])
	print("Top events %s" % ", ".join(top))
	print("----------------------------------------------------------------")
	print("Verbs (ok / refused / skipped)")
	for verb: String in _sorted_strings(_verb_counts.keys()):
		var row: Dictionary = _verb_counts[verb]
		var codes: Array[String] = []
		for code: String in _sorted_strings((row["codes"] as Dictionary).keys()):
			codes.append("%s×%d" % [code, int((row["codes"] as Dictionary)[code])])
		print("  %-22s %4d / %4d / %4d   %s"
				% [verb, int(row["ok"]), int(row["refused"]), int(row["skipped"]),
						", ".join(codes)])
	if not _save_cycles.is_empty():
		print("----------------------------------------------------------------")
		for cycle: Dictionary in _save_cycles:
			print("Save cycle chunk %-4d  %d bytes  hash %s  identity %s / advance %s"
					% [int(cycle["chunk"]), int(cycle["bytes"]),
							String(cycle["hash_before"]).substr(0, 12),
							"OK" if bool(cycle["identical"]) else "DRIFT",
							"OK" if bool(cycle["advance_identical"]) else "DRIFT"])
	for cycle: Dictionary in _pause_cycles:
		print("Pause      away %6.0f s → %6d ticks (%d coarse hours) in %.1f ms, %d events"
				% [float(cycle["elapsed_real_s"]), int(cycle["total_ticks"]),
						int(cycle["coarse_hours"]), float(cycle["usec"]) / 1000.0,
						int(cycle["events"])])
	if not _notes.is_empty():
		print("----------------------------------------------------------------")
		for note: String in _notes:
			print("NOTE  " + note)
	print("================================================================")
	if _failures.is_empty():
		print("SOAK PASSED")
	else:
		for message: String in _failures:
			printerr("SOAK FAIL: " + message)
		printerr("SOAK FAILED (%d)" % _failures.size())


# ---------------------------------------------------------------------------
# Small maths, kept here so the harness owns no library
# ---------------------------------------------------------------------------

## The object series with each reload's retention subtracted from every sample
## that came after it. Sample index and chunk index are the same number (one
## sample per chunk), so a cycle recorded at chunk N is charged to every sample
## after N and to none before it.
func _without_reload_steps(objects: Array[float]) -> Array[float]:
	var out: Array[float] = objects.duplicate()
	for c in _save_cycles.size():
		if c >= _retained_per_reload.size():
			break
		var step := float(maxi(0, _retained_per_reload[c]))
		var at := int((_save_cycles[c] as Dictionary)["chunk"])
		for i in range(at + 1, out.size()):
			out[i] -= step
	return out


func _series(key: String) -> Array[float]:
	var out: Array[float] = []
	for row: Dictionary in _samples:
		out.append(float(row.get(key, 0.0)))
	return out


## Ordinary least squares slope of y over x. Returns 0 for a degenerate x.
static func _slope(xs: Array[float], ys: Array[float]) -> float:
	var n := mini(xs.size(), ys.size())
	if n < 2:
		return 0.0
	var mean_x := 0.0
	var mean_y := 0.0
	for i in n:
		mean_x += xs[i]
		mean_y += ys[i]
	mean_x /= float(n)
	mean_y /= float(n)
	var num := 0.0
	var den := 0.0
	for i in n:
		var dx := xs[i] - mean_x
		num += dx * (ys[i] - mean_y)
		den += dx * dx
	return 0.0 if den <= 0.0 else num / den


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


static func _min_of(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var out: float = values[0]
	for v in values:
		out = minf(out, v)
	return out


static func _max_of(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var out: float = values[0]
	for v in values:
		out = maxf(out, v)
	return out


static func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(round(q * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return sorted[index]


## Mean of the first (or last) tenth of the series, minimum one sample.
static func _decile_mean(values: Array[float], first: bool) -> float:
	if values.is_empty():
		return 0.0
	var n := maxi(1, values.size() / 10)
	var slice: Array[float] = []
	for i in n:
		slice.append(values[i] if first else values[values.size() - 1 - i])
	return _mean(slice)


static func _decile_ratio(values: Array[float]) -> float:
	var first := _decile_mean(values, true)
	if first <= 0.0:
		return 1.0
	return _decile_mean(values, false) / first


func _top_events(limit: int) -> Dictionary:
	var keys := _sorted_strings(_events_by_type.keys())
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ca := int(_events_by_type[a])
		var cb := int(_events_by_type[b])
		return ca > cb if ca != cb else a < b)
	var out: Dictionary = {}
	for i in mini(limit, keys.size()):
		out[keys[i]] = int(_events_by_type[keys[i]])
	return out


static func _sorted_strings(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value: Variant in values:
		out.append(String(value))
	out.sort()
	return out


static func _money(value: float) -> String:
	var sign_text := "-" if value < 0.0 else ""
	var digits := str(int(absf(value)))
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i > 0:
			grouped = "," + grouped
	return "%s$%s" % [sign_text, grouped]


func _fail(message: String) -> void:
	_failures.append(message)


func _note(message: String) -> void:
	if not _notes.has(message):
		_notes.append(message)


static func _write_json(path: String, report: Dictionary) -> void:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("qa_soak: cannot write " + path)
		return
	file.store_string(JSON.stringify(report, "  "))
