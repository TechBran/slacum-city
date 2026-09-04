extends SceneTree
## Headless balance harness (audit doc 93 §E). Boots the real `CitySim`, drives
## it with a SCRIPTED STRATEGY through the real command layer for N game-days,
## samples the city once per game-hour, and writes one JSON per run plus a
## compact terminal table.
##
## It is a MEASURING instrument, not a second simulation: every number it prints
## is read off the live sim, every action it takes goes through `cmd_*`, and it
## owns no balance constant of its own. Nothing here may be imported by `sim/`
## (constitution §3 — this is a tool, it sits above the sim like `ui/` does).
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/playtest.gd -- [options]
##
##   --days=N            game-days per run                    (default 21)
##   --seeds=a,b,c       RNG seeds, one run each              (default 1337,4242,9001)
##   --strategies=a,b    do_nothing|greedy_growth|infrastructure_first|balanced|
##                       tax_squeezer|disaster_neglect|curriculum|all
##                       plus `collector` BY NAME ONLY (RR-86): it is the
##                       curriculum agent with doc 06 §2.16's tap, it only works
##                       at `--mode=fine`, and a 21-game-day run of it costs ~60x
##                       a coarse one — see NAMED_ONLY_STRATEGY_IDS
##   --mode=fine|coarse  fine = the online 4 Hz path (what the player plays);
##                       coarse = doc 01's 1-game-hour offline catch-up path
##                                (~60x faster, and NOT the same city — see
##                                docs/design/92-balance-report.md)   (default fine)
##   --difficulty=NAME   doc 03 §2.9's preset: casual|standard|hard|crisis.
##                       The city is FOUNDED on it and keeps it (doc 93 §K1), so
##                       it is a boot argument. `standard` is the control every
##                       table in doc 92 before §29 is measured on  (default standard)
##   --out=DIR           output directory              (default res://build/playtest)
##   --no-json           terminal table only
##   --quiet             suppress the per-run progress lines
##   --experiment=NAME   run a controlled micro-experiment instead of the
##                       strategy matrix: `transformer_payback` or `tax_curve`.
##                       These answer questions a strategy run cannot isolate
##                       (what does one transformer buy? what does one tax
##                       detent cost?) by moving ONE variable at a time.
##
## Determinism: the harness makes no stochastic choices. Site selection scans
## sorted block ids and row-major tiles; archetype preference lists are sorted
## with an id tie-break; every dictionary iterated for output is sorted. Same
## seed + same strategy + same mode ⇒ byte-identical sample stream (asserted by
## `tests/test_playtest_harness.gd`).

## 2 — pass 2 added the maintenance/land/grid/tax columns to `samples` and
## `summary`. `tools/playtest_report.py` reads the version and refuses older files.
const SCHEMA_VERSION := 2
const DEFAULT_DAYS := 21
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const DEFAULT_OUT_DIR := "res://build/playtest"
const HOURS_PER_DAY := 24
## `GameClock.TICKS_PER_HOUR / TICKS_PER_MINUTE` = 240/4. Named here because the
## fine slice divides by it (`Runner.advance_hour_by_minutes`) and a slice that
## did not land on a whole number of ticks would silently re-rate every agent.
const MINUTES_PER_HOUR := 60

## Report order, not alphabetical: the control first, then the four players, then
## the two single-variable variants of `balanced` (see the class comments —
## `tax_squeezer` and `disaster_neglect` differ from `balanced` in exactly one
## knob each, which is what makes their curves readable as a cause).
const STRATEGY_IDS: Array[String] = [
	"do_nothing", "greedy_growth", "infrastructure_first", "balanced",
	"tax_squeezer", "disaster_neglect",
	# Wave 9 — doc 09 §2.14's student. Last in the list, and deliberately not in
	# `tests/balance_matrix.gd`'s default six: the matrix is doc 92's fitted
	# sample and adding a seventh row to it would re-base every mean in the
	# report. It is run by name, and by `test_balance_gates.gd` gate 21.
	"curriculum",
]

## Strategies that exist, are runnable BY NAME, and are deliberately NOT in
## `all` (RR-86).
##
## `collector` is the project's first FINE-PATH agent. Doc 06 §2.16's spawner
## draws nothing on the coarse step — that is doc 08's offline-fairness rule
## expressed where it is enforceable — so an agent that taps street opportunities
## is only an agent at `--mode=fine`, where a 21-game-day run costs roughly sixty
## times what the coarse matrix costs. Putting it in `all` would make the tool's
## default run an hour long and would add an eighth row to a table doc 92 has
## published seven of. It is run by name, and by `test_balance_gates.gd` gate 32.
const NAMED_ONLY_STRATEGY_IDS: Array[String] = [
	"collector",
	# Wave 18 — `balanced` that also PREPARES (99-PA PA-26). Named-only for the
	# same reason `collector` is: it differs from `balanced` on the handful of
	# game-hours a storm is pending, so on the 21-game-day matrix horizon it is
	# mostly the same agent, and adding it to `all` would put an eighth row in a
	# table doc 92 has published seven of. It earns its keep on a horizon long
	# enough to contain a `severe_thunderstorm`.
	"storm_ready",
]

## Verbs the harness knows how to drive. Present ones are used, absent ones are
## recorded and skipped. As of Wave 1.5 every one of these exists; the probe
## stays because it is what keeps a mid-wave harness from crashing.
const KNOWN_VERBS: Array[String] = [
	"cmd_place_building", "cmd_upgrade_building", "cmd_repair_building",
	"cmd_demolish_building", "cmd_buy_block", "cmd_start_development",
	"cmd_set_tax_level", "cmd_set_priority", "cmd_place_grid_component",
	# Wave 5's infrastructure verbs. They are PROBED but not yet driven by any
	# strategy: roads arrive stamped with doc 09's block template and water
	# arrives with doc 09's authored topology, so neither is on the critical
	# path of a 21-game-day run. A strategy that lays its own street grid or
	# builds a second pump station is the next pass's measurement — recording
	# them here is what makes their absence from the report visible rather than
	# silent.
	"cmd_place_road", "cmd_upgrade_road", "cmd_demolish_road",
	"cmd_place_water_component", "cmd_place_water_main",
	"cmd_upgrade_water_component",
	# Wave 6's doc 04 §4 `route_feeder`. `Balanced` drives it through the one-tap
	# `cmd_place_grid_component("feeder", …)` door; Wave 11 gave the verb a real
	# card on doc 12 §2.7's drag-path tool (doc 93 §J2) and `InfrastructureFirst`
	# now drives it too, because an agent whose whole thesis is "bones before
	# income" cannot watch the tap and ignore the trunk it hangs off.
	"cmd_route_feeder",
	# Wave 15 — doc 06 §2.16's tap. The first verb in this list that only exists
	# on the FINE path: opportunities do not spawn during a coarse step, so a
	# coarse agent that drove this would drive it against an empty roster forever.
	"cmd_collect_opportunity",
	# Wave 18 — doc 07 §2.7.7's preparation window (99-PA PA-26). Driven only by
	# `storm_ready`, because it is reachable only inside the T−90 → T−20 window
	# of a committed `severe_thunderstorm` and an agent that is not watching for
	# one would record nothing but `E_NO_STORM`.
	"cmd_storm_prep_action",
]


func _initialize() -> void:
	var opts := Options.parse(OS.get_cmdline_user_args())
	if not opts.errors.is_empty():
		for message in opts.errors:
			printerr("playtest: " + message)
		quit(2)
		return
	if opts.experiment != "":
		Experiments.run(opts.experiment, opts)
		quit(0)
		return

	var runs: Array[Dictionary] = []
	for strategy_id in opts.strategies:
		for seed_value in opts.seeds:
			var report := Runner.run_one(strategy_id, seed_value, opts)
			runs.append(report)
			if not opts.quiet:
				var summary: Dictionary = report["summary"]
				print("  %-20s seed %-6d -> treasury $%-10s pop %-6d hap %5.1f stab %.4f  L%d  %s" % [
					strategy_id, seed_value,
					Fmt.thousands(int(summary["treasury_end"])),
					int(summary["population_end"]),
					float(summary["happiness_end"]),
					float(summary["stability_end"]),
					int(summary["city_level_end"]),
					String(report["digest"]).substr(0, 12)])
			if opts.write_json:
				# The preset is in the NAME, not only in the body: a `crisis` run
				# and the `standard` control are different cities, and a run that
				# silently overwrote the control would be the worst artifact this
				# tool could produce. `standard` keeps its historical filename so
				# every report already on disk still matches.
				var suffix := "" if opts.difficulty == Difficulty.DEFAULT_PRESET \
						else "_" + opts.difficulty
				var path: String = "%s/%s_seed%d_d%d_%s%s.json" % [
						opts.out_dir, strategy_id, seed_value, opts.days, opts.mode,
						suffix]
				_write_json(path, report)

	Table.print_all(runs, opts)
	quit(0)


static func _write_json(path: String, report: Dictionary) -> void:
	var dir := path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		printerr("playtest: cannot create %s" % dir)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("playtest: cannot write %s" % path)
		return
	# Full precision: the JSON is a determinism artifact as well as a report.
	file.store_string(JSON.stringify(report, "\t", true, true))
	file.close()


# ===========================================================================
# Formatting
# ===========================================================================

## GDScript inner classes cannot see the outer script's static functions (they
## can see its constants), so every helper an inner class needs lives in one.
class Fmt extends RefCounted:

	static func thousands(value: int) -> String:
		var negative := value < 0
		var digits := str(absi(value))
		var out := ""
		var count := 0
		for i in range(digits.length() - 1, -1, -1):
			out = digits[i] + out
			count += 1
			if count % 3 == 0 and i > 0:
				out = "," + out
		return ("-" + out) if negative else out


# ===========================================================================
# Options
# ===========================================================================

class Options extends RefCounted:
	var days: int = DEFAULT_DAYS
	var seeds: Array[int] = DEFAULT_SEEDS.duplicate()
	var strategies: Array[String] = STRATEGY_IDS.duplicate()
	var mode: String = "fine"
	## Doc 03 §2.9's difficulty. A city is FOUNDED on it (doc 93 §K1), so it is a
	## boot argument and never a mid-run setter. `standard` is the preset every
	## table in doc 92 before §29 is measured on, and it is printed in the report
	## header so a pasted table can never be mistaken for the control.
	var difficulty: String = Difficulty.DEFAULT_PRESET
	var out_dir: String = DEFAULT_OUT_DIR
	var write_json: bool = true
	var quiet: bool = false
	var experiment: String = ""
	var errors: Array[String] = []

	static func parse(args: PackedStringArray) -> Options:
		var opts := Options.new()
		for raw in args:
			var arg := String(raw)
			if not arg.begins_with("--"):
				opts.errors.append("unexpected argument '%s'" % arg)
				continue
			var body := arg.substr(2)
			var key := body
			var value := ""
			var split := body.find("=")
			if split >= 0:
				key = body.substr(0, split)
				value = body.substr(split + 1)
			match key:
				"days":
					opts.days = maxi(1, int(value))
				"seeds":
					opts.seeds = [] as Array[int]
					for part in value.split(",", false):
						opts.seeds.append(int(part))
					if opts.seeds.is_empty():
						opts.errors.append("--seeds needs at least one seed")
				"strategies":
					opts.strategies = [] as Array[String]
					if value == "all" or value == "":
						opts.strategies = STRATEGY_IDS.duplicate()
					else:
						for part in value.split(",", false):
							var name := String(part).strip_edges()
							if not STRATEGY_IDS.has(name) \
									and not NAMED_ONLY_STRATEGY_IDS.has(name):
								opts.errors.append("unknown strategy '%s' (have %s)"
										% [name, ", ".join(STRATEGY_IDS
												+ NAMED_ONLY_STRATEGY_IDS)])
							else:
								opts.strategies.append(name)
				"mode":
					if value != "fine" and value != "coarse":
						opts.errors.append("--mode must be fine or coarse")
					else:
						opts.mode = value
				"difficulty":
					if not Difficulty.is_preset(value):
						opts.errors.append("unknown difficulty '%s' (have %s)"
								% [value, ", ".join(Difficulty.PRESETS)])
					else:
						opts.difficulty = value
				"out":
					opts.out_dir = value
				"no-json":
					opts.write_json = false
				"quiet":
					opts.quiet = true
				"experiment":
					if not Experiments.NAMES.has(value):
						opts.errors.append("unknown experiment '%s' (have %s)"
								% [value, ", ".join(Experiments.NAMES)])
					else:
						opts.experiment = value
				_:
					opts.errors.append("unknown option '--%s'" % key)
		return opts

	func hours() -> int:
		return days * HOURS_PER_DAY


# ===========================================================================
# The command-layer facade every strategy talks through
# ===========================================================================

## Wraps `CitySim` so a strategy never touches the sim's internals for anything
## it could not do through the UI. Every command call is logged with its reason
## code, which is what makes the failure histogram in the report possible.
class Api extends RefCounted:
	const BLOCK_TILES := 16
	## Doc 04 §8 / `PowerGrid.TRANSFORMER_SERVICE_RADIUS[0]` — the L1 tap covers
	## Chebyshev 3, i.e. a 7×7 patch. Asserted against the live constant in
	## `tests/test_playtest_harness.gd` so a doc-04 retune cannot silently
	## invalidate the siting heuristic.
	const TRANSFORMER_L1_RADIUS := 3
	## How many unserved tiles the transformer siting scan scores. Bounded so a
	## once-every-few-hours call stays cheap on a 9-block city; the tiles it does
	## not score are the tail of the same row-major order, so the cap costs
	## coverage, never determinism.
	const TRANSFORMER_CANDIDATES := 96

	var sim: CitySim
	var hour: int = 0
	var actions: Array[Dictionary] = []
	var reason_codes: Dictionary = {}
	var placed: int = 0
	var upgraded: int = 0
	var construction_spend: int = 0
	# --- pass-2 verb accounting (doc 93 §B is live; every verb gets a column) --
	var repaired: int = 0
	var repair_spend: int = 0
	var grid_placed: int = 0
	var grid_spend: int = 0
	## Wave 6 — doc 04 §4's `route_feeder`, the verb doc 92 §17.3 named as the
	## late-game's answer. Counted separately from `grid_placed` because a feeder
	## is a different decision at a different scale: a tap is $1k of local ground,
	## a feeder is $5k of trunk capacity that only a substation can root.
	var feeders_routed: int = 0
	## Wave 18 — doc 07 §2.7.7's preparation window (99-PA PA-26).
	var storm_preps: int = 0
	var storm_prep_spend: int = 0
	var feeder_spend: int = 0
	var feeder_adopted_kw: float = 0.0
	var substations_built: int = 0
	var demolished: int = 0
	var demolition_refund: int = 0
	var blocks_bought: int = 0
	var land_spend: int = 0
	## Doc 05's placeable roster, driven for the first time by the `curriculum`
	## agent (doc 92 §17.6 recorded that no strategy drove it).
	var water_placed: int = 0
	var water_spend: int = 0
	## Doc 10 §2.13's `cmd_place_road`, driven for the first time by the Wave-10
	## curriculum — the other half of §17.6's gap. Counted in TILES, not in
	## commands: a run is one tap and N bills, and the bill is the interesting
	## number (doc 03 §2.13(d)'s 17–52× piece-rate premium over the template).
	var road_tiles_built: int = 0
	var road_spend: int = 0
	var tax_changes: int = 0
	var priority_sets: int = 0
	## `cmd_place_building` answers `E_UNSERVED`: the wall a player without a
	## transformer runs into. Counting it is the whole point of `greedy_growth`.
	var unserved_walls: int = 0
	# --- Wave 15: doc 06 §2.16's tap (RR-86) ---------------------------------
	## Offers taken, and the dollars they paid. `street_income` is the ONLY
	## number in this harness that measures the layer on an arc: doc 92 §35.2's
	## ceiling was computed from spawn telemetry on a city that never changed,
	## and a 21-game-day city changes on every axis the bounty formula reads —
	## `city_level` scales the reward, the road graph grows the kerb pool, and a
	## second police station moves the whole kind mix.
	var opportunities_collected: int = 0
	var street_income: int = 0
	var street_missed: int = 0
	## `city_level` -> `{"n": int, "dollars": int, "hours": int}`. Doc 92 §35.3's
	## second-order question 4 in a column: is `STREET_REWARD_CITY_LEVEL_K` still
	## paced against a level-4+ city, or does the layer outrun the city it scales
	## with? The ceiling measurement could not ask — it never left level 0.
	var street_by_level: Dictionary = {}

	## verb name -> {"present": bool, "args": int, "required": int}
	var verbs: Dictionary = {}

	var _block_cursor: int = 0
	var _disabled: Dictionary = {}

	func _init(p_sim: CitySim) -> void:
		sim = p_sim
		for verb in KNOWN_VERBS:
			verbs[verb] = _probe(verb)

	func _probe(verb: String) -> Dictionary:
		for entry in sim.get_method_list():
			if String(entry["name"]) != verb:
				continue
			var args: Array = entry.get("args", [])
			var defaults: Array = entry.get("default_args", [])
			return {"present": true, "args": args.size(),
					"required": args.size() - defaults.size()}
		return {"present": false, "args": 0, "required": 0}

	func has_verb(verb: String) -> bool:
		return bool(verbs.get(verb, {}).get("present", false)) and not _disabled.has(verb)

	func balance() -> int:
		return sim.treasury.balance

	func city_level() -> int:
		return sim.progression.city_level

	func tax_level() -> int:
		return sim.tax_level()

	func build_cost(archetype: String) -> int:
		return sim.econ_curves.build_cost(archetype)

	func min_city_level(archetype: String) -> int:
		return int(sim.catalog.stats(archetype, 1).get("min_city_level", 0))

	func footprint(archetype: String) -> Vector2i:
		var foot: Array = sim.catalog.stats(archetype, 1).get("footprint", [1, 1])
		return Vector2i(int(foot[0]), int(foot[1]))

	## Sorted archetype ids the player may build right now, filtered by category
	## set and by the build sheet's own `locked` rule (min_city_level). NOTE the
	## rule is a UI gate only today — `cmd_place_building` does not enforce it
	## (recorded as finding F-5 in doc 92); the harness plays by the UI's rules.
	func buildable(categories: Array) -> Array[String]:
		var out: Array[String] = []
		for id in sim.catalog.archetypes():
			var archetype := String(id)
			if not categories.has(sim.catalog.category(archetype)):
				continue
			if min_city_level(archetype) > city_level():
				continue
			out.append(archetype)
		out.sort()
		return out

	## Deterministic site search: owned+READY blocks in sorted id order starting
	## at a round-robin cursor, then row-major tiles inside the block. The first
	## tile that is placeable AND inside a transformer's reach wins.
	func candidate_site(size: Vector2i) -> Vector2i:
		var blocks := _ready_blocks()
		if blocks.is_empty():
			return Vector2i(-1, -1)
		for offset in blocks.size():
			var block: LandBlock = sim.world.block(blocks[(_block_cursor + offset) % blocks.size()])
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES - size.y + 1):
				for x in range(x0, x0 + BLOCK_TILES - size.x + 1):
					var origin := Vector2i(x, z)
					if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
						return origin
		return Vector2i(-1, -1)

	## Every buildable tile in an owned+READY block that NO transformer reaches —
	## i.e. every tile where `cmd_place_building` answers `E_UNSERVED`. Row-major
	## inside sorted block ids, so the order is the same on every run.
	func unserved_tiles() -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES):
				for x in range(x0, x0 + BLOCK_TILES):
					var tile := Vector2i(x, z)
					if sim.world.grid.can_place(tile, Vector2i.ONE) \
							and not sim.grid.would_serve(tile):
						out.append(tile)
		return out

	## The first buildable tile in an owned+READY block that NO transformer
	## reaches. This is the wall — and where a transformer wants to go.
	func unserved_site() -> Vector2i:
		var tiles := unserved_tiles()
		return tiles[0] if not tiles.is_empty() else Vector2i(-1, -1)

	## The first placeable `size` footprint that no transformer reaches, so a
	## strategy can deliberately walk into `E_UNSERVED` and have the command
	## layer say so. `candidate_site` is its served twin.
	func unserved_footprint(size: Vector2i) -> Vector2i:
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES - size.y + 1):
				for x in range(x0, x0 + BLOCK_TILES - size.x + 1):
					var origin := Vector2i(x, z)
					if sim.world.grid.can_place(origin, size) \
							and not sim.grid.would_serve(origin):
						return origin
		return Vector2i(-1, -1)

	## Where an L1 transformer buys the most ground: the candidate tile whose
	## Chebyshev-3 patch contains the most currently-unserved buildable tiles.
	## Scores at most `TRANSFORMER_CANDIDATES` tiles against a hash set of the
	## whole unserved roster, so the cost is ~96 × 49 lookups, not a map sweep.
	## Ties break on the row-major order the scan already produced, which is what
	## keeps two runs of the same seed byte-identical.
	func best_transformer_tile() -> Vector2i:
		var tiles := unserved_tiles()
		if tiles.is_empty():
			return Vector2i(-1, -1)
		return _densest(tiles)

	static func _tile_key(tile: Vector2i) -> int:
		return tile.x * 1024 + tile.y

	## Per-BLOCK grid coverage, which is the shape the "ahead of growth" rule
	## actually needs. Returns the best transformer tile in the first owned+READY
	## block holding fewer than `lead` served, buildable, empty tiles — or
	## (−1,−1) when every block is comfortable.
	##
	## Per block, not city-wide, because the founding core ships with 510 served
	## spare tiles and would mask a brand-new block where all 256 answer
	## `E_UNSERVED`: doc 09 §2.3's pipeline lays a utility corridor to the block
	## centre and **no transformer**, so bought land is dark land until the
	## player buys the tap. The scan early-outs the moment a block reaches
	## `lead`, so a comfortable block costs a handful of tile probes.
	func grid_shortfall_tile(lead: int) -> Vector2i:
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			var dark: Array[Vector2i] = []
			var served := 0
			for z in range(z0, z0 + BLOCK_TILES):
				if served >= lead:
					break
				for x in range(x0, x0 + BLOCK_TILES):
					var tile := Vector2i(x, z)
					if not sim.world.grid.can_place(tile, Vector2i.ONE):
						continue
					if sim.grid.would_serve(tile):
						served += 1
						if served >= lead:
							break
					else:
						dark.append(tile)
			if served >= lead or dark.is_empty():
				continue
			return _densest(dark)
		return Vector2i(-1, -1)

	## The tile in `tiles` with the most of `tiles` inside its L1 service patch.
	func _densest(tiles: Array[Vector2i]) -> Vector2i:
		var present := {}
		for tile in tiles:
			present[_tile_key(tile)] = true
		var best := tiles[0]
		var best_score := -1
		var scanned: int = mini(tiles.size(), TRANSFORMER_CANDIDATES)
		for index in scanned:
			var candidate: Vector2i = tiles[index]
			var score := 0
			for dz in range(-TRANSFORMER_L1_RADIUS, TRANSFORMER_L1_RADIUS + 1):
				for dx in range(-TRANSFORMER_L1_RADIUS, TRANSFORMER_L1_RADIUS + 1):
					if present.has(_tile_key(candidate + Vector2i(dx, dz))):
						score += 1
			if score > best_score:
				best_score = score
				best = candidate
		return best

	## The first block the city is allowed to buy (doc 09 §2.5: city level plus a
	## full shared edge with an owned block), computed fresh rather than read off
	## `ownership_state`, which nothing refreshes today.
	func purchasable_block() -> String:
		for id in sim.world.block_ids_sorted():
			var block_id := String(id)
			var block: LandBlock = sim.world.block(block_id)
			if block == null or block.is_owned():
				continue
			if bool(sim.world.purchase_allowed(block_id, city_level())["ok"]):
				return block_id
		return ""

	func _ready_blocks() -> Array[String]:
		var out: Array[String] = []
		for id in sim.world.block_ids_sorted():
			var block: LandBlock = sim.world.block(String(id))
			if block != null and block.is_owned() and block.is_ready():
				out.append(String(id))
		return out

	## Place one building of `archetype`. Returns the command result verbatim
	## (plus an `origin` key) so the strategy can read reason codes.
	##
	## `into_the_wall` is what makes `greedy_growth` an experiment rather than a
	## bot: when every transformer-served site is taken, an agent that refuses to
	## buy grid still tries to build, and the command layer answers `E_UNSERVED`.
	## Counting those answers is how this report prices the transformer.
	func place(archetype: String, into_the_wall: bool = false) -> Dictionary:
		if not has_verb("cmd_place_building"):
			return _log("place", archetype, CommandQueue.fail(&"E_NO_VERB"), {})
		var size := footprint(archetype)
		var origin := candidate_site(size)
		if origin.x < 0 and into_the_wall:
			origin = unserved_footprint(size)
		if origin.x < 0:
			return _log("place", archetype, CommandQueue.fail(&"E_NO_SITE"), {})
		var result: Dictionary = sim.cmd_place_building(archetype, origin)
		if bool(result["ok"]):
			placed += 1
			construction_spend += int(result["payload"].get("cost", 0))
			_block_cursor += 1
		elif String(result["reason_code"]) == "E_UNSERVED":
			unserved_walls += 1
		return _log("place", archetype, result, {"origin": [origin.x, origin.y]})

	## `place`, ranked by distance to `centre` instead of by the round-robin
	## block cursor. Still the HARNESS's site search — the strategy names a
	## centre, never a tile — and it exists for exactly one archetype class: a
	## grid SOURCE. A substation is bought to feed a specific overloaded circuit
	## and the feeder that leaves it is priced per tile (doc 03 §2.13(b)), so
	## siting it wherever the cursor happened to point would price the decision
	## by an accident of the scan order rather than by the decision. Ties break
	## row-major inside sorted block ids, as every other search here does.
	func place_near(archetype: String, centre: Vector2i) -> Dictionary:
		if not has_verb("cmd_place_building"):
			return _log("place_near", archetype, CommandQueue.fail(&"E_NO_VERB"), {})
		var size := footprint(archetype)
		var origin := site_near(size, centre)
		if origin.x < 0:
			return _log("place_near", archetype, CommandQueue.fail(&"E_NO_SITE"), {})
		var result: Dictionary = sim.cmd_place_building(archetype, origin)
		if bool(result["ok"]):
			placed += 1
			construction_spend += int(result["payload"].get("cost", 0))
		return _log("place_near", archetype, result, {"origin": [origin.x, origin.y]})

	## The placeable, served footprint of `size` nearest `centre` (Chebyshev),
	## scanned row-major inside sorted owned+READY block ids so the tie-break is
	## the same on every run.
	func site_near(size: Vector2i, centre: Vector2i) -> Vector2i:
		var best := Vector2i(-1, -1)
		var best_distance := 999999
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES - size.y + 1):
				for x in range(x0, x0 + BLOCK_TILES - size.x + 1):
					var origin := Vector2i(x, z)
					var distance: int = maxi(absi(x - centre.x), absi(z - centre.y))
					if distance >= best_distance:
						continue
					if sim.world.grid.can_place(origin, size) \
							and sim.grid.would_serve(origin):
						best = origin
						best_distance = distance
		return best

	## Place at a NAMED tile rather than at the next candidate site. Only the
	## controlled experiments use this: a strategy must take the ground the
	## harness's own site search offers it, or its curve stops being comparable.
	func place_at(archetype: String, origin: Vector2i) -> Dictionary:
		if not has_verb("cmd_place_building"):
			return _log("place", archetype, CommandQueue.fail(&"E_NO_VERB"), {})
		var result: Dictionary = sim.cmd_place_building(archetype, origin)
		if bool(result["ok"]):
			placed += 1
			construction_spend += int(result["payload"].get("cost", 0))
		elif String(result["reason_code"]) == "E_UNSERVED":
			unserved_walls += 1
		return _log("place", archetype, result, {"origin": [origin.x, origin.y]})

	## The doc 02 §2.11 gate, read-only. `{ok, blockers, cost}`.
	func upgrade_preview(sim_id: String) -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return CommandQueue.fail(&"E_NO_VERB")
		return sim.cmd_upgrade_building(sim_id, true)

	func upgrade(sim_id: String) -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return _log("upgrade", sim_id, CommandQueue.fail(&"E_NO_VERB"), {})
		var result: Dictionary = sim.cmd_upgrade_building(sim_id, false)
		if bool(result["ok"]):
			upgraded += 1
			construction_spend += int(result["payload"].get("cost", 0))
		return _log("upgrade", sim_id, result, {})

	## How many gate-clearing rows `upgrade_candidates` returns, and how many
	## rows it is willing to price to find them.
	##
	## **Doc 92 pass-2 F-10, closed.** Pass 2 previewed `cmd_upgrade_building` for
	## EVERY standing building on every call, and the agents call it up to six
	## times a game-hour, so the harness cost `O(buildings × hours)` previews and
	## one matrix run of 18 did not finish inside the wall-clock budget. It is
	## also what made the Wave-4 rebalance unmeasurable: the rebalanced `balanced`
	## builds a 358-building city, and a 21-game-day run went from 12 s to over 13
	## minutes on the preview scan alone.
	##
	## The fix is doc 92 F-10's own recommendation: **rank on the cheap fields,
	## price only the head.** Upgrade price is `econ_curves.upgrade_cost(type,
	## level)` — a pure function of (archetype, level) with no gate in it — so the
	## cost ordering is known before a single preview runs. Only the ordered head
	## is previewed, and only until `UPGRADE_LIMIT` rows have cleared the doc 02
	## §2.11 gate. Both consumers rank on a cheap key (cost for `balanced`,
	## heads-per-dollar for `greedy_growth`) and take the head, so the bound is
	## invisible to them unless more than `UPGRADE_SCAN` of the cheapest rows are
	## all gate-blocked at once.
	const UPGRADE_LIMIT := 8
	const UPGRADE_SCAN := 64

	## [archetype_upgrade_candidate]'s own scan depth, and it is deliberately
	## much shallower than [UPGRADE_SCAN] (Wave 22). That method is asked twelve
	## times a game-hour for the whole of doc 09 §2.14.2's level 7, and each
	## preview it takes runs `CitySim.peak_component_loads()`. Eight is the
	## cheapest depth that still answers the question it is asked: an archetype
	## whose eight cheapest instances are ALL refused is refused for a city-wide
	## reason — power headroom, water headroom — and a ninth instance of the same
	## archetype would be refused for the same one.
	const ARCHETYPE_SCAN := 8

	## Every upgradeable building, cheapest first, id tie-break. Each entry is
	## `{sim_id, cost, level, archetype}`; only clear-gate rows are returned.
	func upgrade_candidates(categories: Array = []) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if not has_verb("cmd_upgrade_building"):
			return out
		var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
		var ranked: Array[Dictionary] = []
		for id in _sorted(sim.buildings):
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level >= b.max_level:
				continue
			var archetype := String(b.archetype)
			if not categories.is_empty() and not categories.has(sim.catalog.category(archetype)):
				continue
			ranked.append({"sim_id": sim_id, "archetype": archetype, "level": b.level,
					"cost": sim.econ_curves.upgrade_cost(archetype, b.level, m_build)})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["cost"]) != int(b["cost"]):
				return int(a["cost"]) < int(b["cost"])
			return String(a["sim_id"]) < String(b["sim_id"]))
		for i in mini(ranked.size(), UPGRADE_SCAN):
			var row: Dictionary = ranked[i]
			var preview := upgrade_preview(String(row["sim_id"]))
			if not bool(preview["ok"]):
				continue
			row["cost"] = int(preview["payload"].get("cost", row["cost"]))
			out.append(row)
			if out.size() >= UPGRADE_LIMIT:
				break
		return out

	## The cheapest building OF ONE ARCHETYPE that can upgrade right now, or `{}`
	## when the city has none standing, none below its own top rung, or none that
	## clears the gate. Same row shape as [upgrade_candidates].
	##
	## It exists for doc 09 §2.14.2's level 7 — *one upgraded building of each
	## type* — and it is a third ranking rather than a filter on either of the
	## two above, for the reason the [top_upgrade_candidate] docstring gives one
	## paragraph up: a cheapest-first list over the whole roster is all houses,
	## and a progress-first list is all towers. Neither can be asked "and what
	## about the fire station?".
	func archetype_upgrade_candidate(archetype: String) -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return {}
		var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
		var ranked: Array[Dictionary] = []
		# NOT `_sorted(sim.buildings)`: this is asked twelve times a game-hour
		# for the whole of level 7, and sorting six hundred ids to keep eight of
		# them was measurably the most expensive thing the agent did. The
		# `sort_custom` below is TOTAL (cost, then id), so the answer does not
		# depend on the order the roster was walked in.
		for id: Variant in sim.buildings:
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level >= b.max_level:
				continue
			if String(b.archetype) != archetype:
				continue
			ranked.append({"sim_id": sim_id, "archetype": archetype, "level": b.level,
					"cost": sim.econ_curves.upgrade_cost(archetype, b.level, m_build)})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["cost"]) != int(b["cost"]):
				return int(a["cost"]) < int(b["cost"])
			return String(a["sim_id"]) < String(b["sim_id"]))
		for i in mini(ranked.size(), ARCHETYPE_SCAN):
			var row: Dictionary = ranked[i]
			var preview := upgrade_preview(String(row["sim_id"]))
			if not bool(preview["ok"]):
				continue
			row["cost"] = int(preview["payload"].get("cost", row["cost"]))
			return row
		return {}


	## How many buildings of `archetype` the city is standing up right now, in
	## any state. The question "do I own one of these at all?" — which is a
	## different question from "can I upgrade one", and the one that decides
	## whether the answer to a level-7 row is BUILD or UPGRADE.
	func archetype_count(archetype: String) -> int:
		var count := 0
		for id: Variant in sim.buildings:
			var b: Building = sim.buildings[String(id)]
			if String(b.archetype) == archetype:
				count += 1
		return count


	## The building CLOSEST to the top of its own ladder that can upgrade right
	## now, highest level first, cost then id as tie-breaks. `{}` when none can.
	##
	## [upgrade_candidates] ranks the other way — cheapest first — and that is
	## right for an agent buying capacity by the dollar, but it is exactly wrong
	## for the doc 09 §2.14 objective "take a building all the way to level 6":
	## the cheapest upgrade in a city of a hundred houses is always another
	## L1 → L2, so an agent chasing the top rung on the cheap list never leaves
	## the bottom one. This ranks on PROGRESS instead, which is what a player
	## following that instruction does — they pick the tall one and keep going.
	func top_upgrade_candidate() -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return {}
		var m_build := float(sim.treasury.difficulty().get("M_build", 1.0))
		var ranked: Array[Dictionary] = []
		for id in _sorted(sim.buildings):
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level >= b.max_level:
				continue
			ranked.append({"sim_id": sim_id, "archetype": String(b.archetype),
					"level": b.level, "top": b.max_level,
					"cost": sim.econ_curves.upgrade_cost(String(b.archetype), b.level, m_build)})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["level"]) != int(b["level"]):
				return int(a["level"]) > int(b["level"])
			if int(a["cost"]) != int(b["cost"]):
				return int(a["cost"]) < int(b["cost"])
			return String(a["sim_id"]) < String(b["sim_id"]))
		for i in mini(ranked.size(), UPGRADE_SCAN):
			var row: Dictionary = ranked[i]
			var preview := upgrade_preview(String(row["sim_id"]))
			if not bool(preview["ok"]):
				continue
			row["cost"] = int(preview["payload"].get("cost", row["cost"]))
			return row
		return {}

	# --- the doc 93 §B verbs ------------------------------------------------

	func repair(sim_id: String) -> Dictionary:
		var result := _optional("cmd_repair_building", 1, [sim_id], sim_id)
		if bool(result["ok"]):
			repaired += 1
			repair_spend += int((result["payload"] as Dictionary).get("cost", 0))
		return result

	# --- doc 10 §2.13's road verbs, through the door the ROADS tab opens -----

	## The run the player's thumb would draw: `tiles` fresh tiles starting beside
	## a road the city already has, inside a block that is owned and READY.
	##
	## Same shape as `candidate_site()` — the HARNESS finds the ground, the
	## strategy names only how much of it it wants — and the same determinism
	## rule: sorted block ids, row-major inside each, first fit. It mirrors what
	## `ui/path_tool.gd` makes the player do (anchor beside the network, sweep a
	## straight leg), because a measurement of a verb has to measure the door the
	## verb actually has.
	func road_run(tiles: int) -> Array[Vector2i]:
		var wanted := maxi(1, tiles)
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES):
				for x in range(x0, x0 + BLOCK_TILES):
					var start := Vector2i(x, z)
					if not _road_layable(start) or not _touches_road(start):
						continue
					for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
						var run: Array[Vector2i] = []
						var at := start
						while run.size() < wanted and _road_layable(at):
							run.append(at)
							at += step
						if run.size() == wanted:
							return run
		return [] as Array[Vector2i]

	## Free ground a road tile may be stamped on: in bounds, not already paved,
	## not occupied, and on land doc 09 says is buildable.
	func _road_layable(tile: Vector2i) -> bool:
		if not TileGrid.in_bounds(tile.x, tile.y):
			return false
		if sim.world.grid.road_class_at(tile.x, tile.y) != TileGrid.ROAD_NONE:
			return false
		if not sim.world.grid.can_place(tile, Vector2i.ONE):
			return false
		var block := sim.world.block_of_tile(tile.x, tile.y)
		return block != null and block.is_owned() and block.is_ready()

	## Doc 10 §2.13's `E_NOT_CONNECTED` in one read: does this tile sit beside
	## pavement the city already owns?
	func _touches_road(tile: Vector2i) -> bool:
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q := tile + d
			if TileGrid.in_bounds(q.x, q.y) \
					and sim.world.grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
				return true
		return false

	## What laying `tiles` of street would cost, off `cmd_place_road`'s own
	## preview. `0` when there is nowhere to lay it — an agent saving for a run
	## it cannot site would save for ever.
	func road_quote(tiles: int, road_class: int = TileGrid.ROAD_STREET) -> int:
		if not has_verb("cmd_place_road"):
			return 0
		var run := road_run(tiles)
		if run.is_empty():
			return 0
		var raw: Array = []
		for tile: Vector2i in run:
			raw.append(tile)
		var quote: Dictionary = sim.cmd_place_road(raw, road_class, true)
		return int((quote.get("payload", {}) as Dictionary).get("cost", 0))

	func place_road(tiles: int, road_class: int = TileGrid.ROAD_STREET) -> Dictionary:
		var run := road_run(tiles)
		if run.is_empty():
			return _log("place_road", "%d tiles" % tiles,
					CommandQueue.fail(&"E_NO_SITE"), {})
		var raw: Array = []
		for tile: Vector2i in run:
			raw.append(tile)
		var result := _optional("cmd_place_road", 2, [raw, road_class],
				"%d tiles @%d,%d" % [run.size(), run[0].x, run[0].y])
		if bool(result["ok"]):
			var payload: Dictionary = result["payload"]
			road_tiles_built += int(payload.get("tiles", run.size()))
			road_spend += int(payload.get("cost", 0))
		return result

	## What one repair would cost, read straight off `cmd_repair_building`'s own
	## preview (doc 02 §2.6 × doc 03 `REPAIR_COST_PER_CAPITAL`). Read-only, and
	## never logged — a budget-gated agent has to price the job before it takes
	## it, and a quote is not an action.
	func repair_quote(sim_id: String) -> int:
		if not has_verb("cmd_repair_building"):
			return 0
		var quote: Dictionary = sim.cmd_repair_building(sim_id, true)
		return int((quote.get("payload", {}) as Dictionary).get("cost", 0))

	## The last settled game-hour's net, as doc 03 billed it. `0.0` before the
	## first settlement. This is what a budget-gated maintenance policy sizes its
	## purse against — the city's own income, not a held constant.
	func last_net() -> float:
		return float((sim.last_settlement.get("net", 0.0)))

	# --- doc 06 §2.16: the tap (Wave 15, RR-86) ------------------------------

	## Collect the NEAREST live street opportunity to `centre`, within
	## `radius_m` ground metres, through the same funnel the shell's tap uses:
	## `OpportunitySystem.opportunity_near()` picks the row and
	## `cmd_collect_opportunity` takes the money. One tap, one offer — an agent
	## that emptied the roster in a single call would be measuring a verb the
	## player does not have.
	##
	## **`centre` is a TILE and `radius_m` is METRES**, because that is the pair
	## the sim's own query takes (tile centres are `8 m` apart, constitution §6).
	## The conversion is done here rather than at the call site so a strategy
	## never has to know the tile size.
	##
	## Answers the command's own result, so `E_UNKNOWN_OPPORTUNITY` and
	## `E_EXPIRED` land in the reason histogram exactly as a mistimed player tap
	## would. `{}`-empty when nothing is in range: NOT logged, because "there was
	## nothing to tap" is not an action a player took.
	func collect_nearby(centre: Vector2i, radius_m: float) -> Dictionary:
		if not has_verb("cmd_collect_opportunity") or sim.street == null:
			return {}
		var point := Vector3(float(centre.x) * 8.0 + 4.0, 0.0, float(centre.y) * 8.0 + 4.0)
		var offer: Dictionary = sim.street.opportunity_near(point, radius_m)
		if offer.is_empty():
			return {}
		var result: Dictionary = sim.cmd_collect_opportunity(int(offer["id"]))
		_log("collect_opportunity", String(offer.get("kind", "")), result,
				{"reward": int(offer.get("reward", 0))})
		if not bool(result["ok"]):
			street_missed += 1
			return result
		var reward := int((result["payload"] as Dictionary).get("reward", 0))
		opportunities_collected += 1
		street_income += reward
		var level := sim.progression.city_level
		var row: Dictionary = street_by_level.get(level, {"n": 0, "dollars": 0})
		row["n"] = int(row["n"]) + 1
		row["dollars"] = int(row["dollars"]) + reward
		street_by_level[level] = row
		return result

	## How many offers are standing right now. Read-only and never logged — the
	## collector uses it to skip the query entirely on the ~99 game-minutes in a
	## hundred when the street is empty.
	func live_opportunities() -> int:
		return sim.street.live_count() if sim.street != null else 0

	func demolish(sim_id: String) -> Dictionary:
		var result := _optional("cmd_demolish_building", 1, [sim_id], sim_id)
		if bool(result["ok"]):
			demolished += 1
			demolition_refund += int((result["payload"] as Dictionary).get("refund", 0))
		return result

	## `{price, development_estimate}` for one block, off `cmd_buy_block`'s own
	## preview. Returned even when the preview fails on `E_FUNDS` — the quote is
	## in the failure payload, and an agent saving up needs the number precisely
	## when it cannot yet pay it.
	func land_quote(block_id: String) -> Dictionary:
		if not has_verb("cmd_buy_block") or block_id == "":
			return {}
		var result: Dictionary = sim.cmd_buy_block(block_id, true)
		return result.get("payload", {})

	func buy_block(block_id: String) -> Dictionary:
		var result := _optional("cmd_buy_block", 1, [block_id], block_id)
		if bool(result["ok"]):
			blocks_bought += 1
			land_spend += int((result["payload"] as Dictionary).get("price", 0))
		return result

	func start_development(block_id: String) -> Dictionary:
		return _optional("cmd_start_development", 1, [block_id], block_id)

	func set_tax_level(level: Variant) -> Dictionary:
		var result := _optional("cmd_set_tax_level", 1, [level], str(level))
		if bool(result["ok"]) and bool((result["payload"] as Dictionary).get("changed", false)):
			tax_changes += 1
		return result

	func set_priority(sim_id: String, priority_class: String) -> Dictionary:
		var result := _optional("cmd_set_priority", 2, [sim_id, priority_class],
				"%s=%s" % [sim_id, priority_class])
		if bool(result["ok"]):
			priority_sets += 1
		return result

	## How many candidate origins the water siting scan is willing to PRICE.
	## Bounded for the same reason `TRANSFORMER_CANDIDATES` is: the tiles it does
	## not reach are the tail of the same row-major order, so the cap costs
	## coverage, never determinism.
	const WATER_SITE_PREVIEWS := 96

	## Doc 05's `cmd_place_water_component(kind, tile, level = 1, preview =
	## false)`, with the site search the build sheet's ghost does for the player.
	##
	## This one has to PREVIEW rather than reason, and that is the interesting
	## part: a water component needs owned + READY ground, a free footprint **and**
	## a main inside `main_tap_radius_tiles`, and the third condition is doc 05's
	## to answer — `nearest_main_tile` is not something a harness heuristic can
	## reimplement without becoming a second, wrong copy of the rule. So the scan
	## walks row-major inside sorted READY block ids and asks the command; first
	## acceptance wins, which is the same tie-break every other search here uses.
	func place_water_component(kind: String, level: int = 1) -> Dictionary:
		if not has_verb("cmd_place_water_component"):
			return _log("water", kind, CommandQueue.fail(&"E_NO_VERB"), {})
		var rules: Dictionary = sim.water.data.placeable_rules(kind)
		var size: Vector2i = sim.water.data.footprint_of(StringName(kind), level,
				String(rules.get("subtype", "")))
		var previews := 0
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES - size.y + 1):
				for x in range(x0, x0 + BLOCK_TILES - size.x + 1):
					var origin := Vector2i(x, z)
					if not sim.world.grid.can_place(origin, size):
						continue
					previews += 1
					if previews > WATER_SITE_PREVIEWS:
						return _log("water", kind, CommandQueue.fail(&"E_NO_SITE"), {})
					if not bool(sim.cmd_place_water_component(
							kind, origin, level, true)["ok"]):
						continue
					var result: Dictionary = sim.cmd_place_water_component(
							kind, origin, level, false)
					if bool(result["ok"]):
						water_placed += 1
						water_spend += int((result["payload"] as Dictionary).get("cost", 0))
					return _log("water", kind, result, {"origin": [origin.x, origin.y]})
		return _log("water", kind, CommandQueue.fail(&"E_NO_SITE"), {})

	## Doc 93 §B's headline verb ("THE game"). `cmd_place_grid_component(kind,
	## tile, level = 1, preview = false)`.
	##
	## `level` defaults to 1 — the rung the `E_UNSERVED` wall is priced against —
	## but it is a PARAMETER because the roster offers L1–L3 and the choice is a
	## real one: doc 04 §8's ladder gives 50 / 150 / 400 kW for doc 03 §2.13(b)'s
	## $500 / $1,100 / $2,800, i.e. **0.100 / 0.136 / 0.143 kW per dollar**, so L1
	## is the WORST rung on the ladder and the only one whose rating does not
	## cover the ground its own service radius claims. Doc 92 F-11 measured what
	## buying only L1 costs (see `Balanced.GRID_LEVEL`).
	func place_grid_component(kind: String, tile: Vector2i, level: int = 1) -> Dictionary:
		var result := _optional("cmd_place_grid_component", 3, [kind, tile, level],
				"%s L%d@%d,%d" % [kind, level, tile.x, tile.y])
		if bool(result["ok"]):
			grid_placed += 1
			grid_spend += int((result["payload"] as Dictionary).get("cost", 0))
		return result

	## Doc 04 §4's `route_feeder`, through the same one-tap door the build sheet
	## would use: `cmd_place_grid_component("feeder", far_end, conductor_class)`
	## picks the source substation and fills the polyline (the C-41 assist).
	func route_feeder(target: Vector2i, conductor_class: int = 2) -> Dictionary:
		var result := _optional("cmd_place_grid_component", 3,
				["feeder", target, conductor_class],
				"feeder c%d@%d,%d" % [conductor_class, target.x, target.y])
		if bool(result["ok"]):
			var payload: Dictionary = result["payload"]
			feeders_routed += 1
			feeder_spend += int(payload.get("cost", 0))
			feeder_adopted_kw += float(payload.get("adopted_kw", 0.0))
		return result

	## The hottest feeder's load ratio, against the §2.5 DERATED capacity — the
	## number the inverse-time relay trips on, not the nameplate. This is the
	## reading doc 92 §17.3 charted at 51.8 / 80.1 / 104.4 / 119.2 / 111.8 % and
	## the one a competent player watches, because a feeder past 1.05 opens and
	## takes its whole subtree dark with it.
	func feeder_peak_ratio() -> float:
		return float(sim.grid.worst_feeder(_ambient())["load_ratio"])

	## Where new copper wants to go: the tile of the biggest transformer hanging
	## off the hottest feeder. Routing THROUGH the overloaded circuit is what
	## lets doc 04 §2.9's transfer rule move load off it — a feeder drawn into
	## empty ground would only ever carry buildings that do not exist yet.
	func hot_feeder_target() -> Vector2i:
		var worst := String(sim.grid.worst_feeder(_ambient())["id"])
		if worst == "":
			return Vector2i(-1, -1)
		var best := Vector2i(-1, -1)
		var best_load := -1.0
		for id in sim.grid.component_ids_of_kind(&"transformer"):
			var c: Dictionary = sim.grid.component(String(id))
			if String(c["parent"]) != worst:
				continue
			if float(c["load_kw"]) > best_load:
				best_load = float(c["load_kw"])
				best = c["tile"]
		return best

	## The $15,000 answer to `has_feeder_slot() == false`: a new substation,
	## sited near the load it is being bought for.
	func build_substation(centre: Vector2i) -> Dictionary:
		var result := place_near("substation", centre)
		if bool(result["ok"]):
			substations_built += 1
		return result

	## The hottest transformer's load ratio, against the §2.5 derated capacity.
	## A transformer has no protection (§2.5): it does not trip, it cooks, and
	## §2.6's table gives a 52-game-hour MTTF at r = 1.15 and a THREE-game-hour
	## one at r = 1.30. So this reading has to be acted on well under 1.0.
	func transformer_peak_ratio() -> float:
		return float(sim.grid.worst_transformer(_ambient())["load_ratio"])

	## Where a parallel transformer wants to go (doc 04 §2.9): the first legal
	## tile within `radius` of the hottest transformer whose own placement
	## preview says it would actually TAKE load off it. Scanned outward in
	## row-major rings so the choice is the same on every run, and gated on the
	## preview's `relieved_kw` so the agent never buys a tap that relieves
	## nothing.
	func relief_spot(level: int, radius: int) -> Vector2i:
		var hot := sim.grid.worst_transformer(_ambient())
		if String(hot["id"]) == "":
			return Vector2i(-1, -1)
		var centre: Vector2i = hot["tile"]
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var tile := centre + Vector2i(dx, dz)
				if tile == centre:
					continue
				var quote: Dictionary = sim.cmd_place_grid_component(
						"transformer", tile, level, true)
				if not bool(quote["ok"]):
					continue
				if float((quote["payload"] as Dictionary).get("relieved_kw", 0.0)) <= 0.0:
					continue
				return tile
		return Vector2i(-1, -1)

	## The first building that is ONE RUNG SHORT of its own top level and whose
	## upgrade the doc 02 §2.11 gate refuses for POWER, with the tile it stands on
	## and the transformer level that would carry it. `{}` when there is none.
	##
	## **Why this exists** (doc 92 §24.8). Doc 02 §2.14's sixth rung is the first
	## content in the game whose demand curve outruns the copper a competent agent
	## buys by habit: a `house` goes 91 kW → 215 kW across that one step, which is
	## more than the whole 150 kW capacity of the level-2 transformers `Balanced`
	## places. Measured over 45 game-days on three seeds, EVERY level-5 house in
	## the city was refused `E_POWER_HEADROOM` and the tower objective never
	## completed. That is not a balance failure — `k_dem > TAX_LEVEL_GROWTH` is
	## doc 02 §8's deliberate rule that every upgrade is less utility-efficient
	## than the last — it is the agent failing to do the obvious thing the refusal
	## is telling it to do, which is buy copper at the building that was refused.
	func power_blocked_top_rung() -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return {}
		for id in Api._sorted(sim.buildings):
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level < 1 or b.level != b.max_level - 1:
				continue
			var preview: Dictionary = sim.cmd_upgrade_building(sim_id, true)
			var blockers: Array = (preview.get("payload", {}) as Dictionary).get("blockers", [])
			if blockers.is_empty() or String(blockers[0]) != "E_POWER_HEADROOM":
				continue
			var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
			return {"sim_id": sim_id, "tile": b.origin,
					"transformer_level": Api.transformer_level_for(
							float(next_stats.get("power_demand_kw", 0.0)))}
		return {}


	## Raise supply where there is no ROOM for another component (Wave 22, doc 92
	## §61.4). Upgrades the first water node whose own gate lets it, pumps first
	## because doc 05 §2.5's supply term is the pump roster and a bigger tank
	## stores water the zone never had.
	##
	## **Why the second door exists.** `place_water_component` scans the ready
	## blocks for a free footprint, and on the arc the grants produce there is
	## not one: seed 9001 finished 45 game-days with 328 apartments and 164
	## offices standing and **one** successful pump placement in the whole run,
	## because the map was full. A city that cannot build outwards has to build
	## upwards, which is the same sentence doc 09 §2.14.2's level 6 teaches about
	## housing.
	func upgrade_water_node() -> Dictionary:
		if not has_verb("cmd_upgrade_water_component"):
			return CommandQueue.fail(&"E_NO_VERB")
		for wanted: StringName in [&"pump", &"source", &"treatment"]:
			var ids: Array = sim.water.nodes.keys()
			ids.sort()
			for id: Variant in ids:
				var node: WaterNode = sim.water.nodes[id]
				if node.variant != wanted:
					continue
				if not bool(sim.cmd_upgrade_water_component(String(id), true)["ok"]):
					continue
				var result: Dictionary = sim.cmd_upgrade_water_component(String(id), false)
				if bool(result["ok"]):
					water_spend += int((result["payload"] as Dictionary).get("cost", 0))
				return _log("water_upgrade", String(id), result, {})
		return CommandQueue.fail(&"E_NO_SITE")


	## The same second door for copper: upgrade the transformer that is short
	## rather than parallel it, for the same reason and on the same evidence —
	## `relief_spot_near` needs a free tile within [Curriculum.HOTSPOT_RADIUS]
	## and a full map has none. `component_id` is the feeder of the building that
	## was refused, so the copper lands where the refusal happened.
	func upgrade_grid_component(component_id: String) -> Dictionary:
		if not has_verb("cmd_upgrade_grid_component") or component_id == "":
			return CommandQueue.fail(&"E_NO_VERB")
		if not bool(sim.cmd_upgrade_grid_component(component_id, true)["ok"]):
			return CommandQueue.fail(&"E_BLOCKED")
		# No counter of its own: `_log` already records the verb, the subject and
		# the verdict, and the summary's `substations_built` counts SHELLS. An
		# upgraded transformer is neither a new shell nor a new component.
		return _log("grid_upgrade", component_id,
				sim.cmd_upgrade_grid_component(component_id, false), {})


	## [power_blocked_top_rung]'s sibling, asked of ONE ARCHETYPE and of any rung
	## (Wave 22, doc 92 §61.4). Returns the first standing building of
	## `archetype` whose upgrade the doc 02 §2.11 gate refuses, with the FIRST
	## blocker on its checklist, the tile it stands on, and the transformer rung
	## that would carry its next step. `{}` when none of them is blocked.
	##
	## **Why it had to exist.** Doc 09 §2.14.2's level 7 asks for one upgrade of
	## each of the twelve archetypes, and the first 45-game-day measurement of it
	## (doc 92 §61.4) came back with four rows unmet, a $2,018,221 treasury and
	## the same two words on every refusal in the city: `E_POWER_HEADROOM` and
	## `E_WATER_HEADROOM`. The capstone is not a money wall, it is a UTILITY
	## wall — which is the right lesson for the last level and the wrong thing
	## for an agent to be unable to answer. `power_blocked_top_rung` could not
	## answer it: it only looks at buildings one rung short of their top, and a
	## level-1 fire station is five rungs short of nothing.
	func blocked_upgrade(archetype: String) -> Dictionary:
		if not has_verb("cmd_upgrade_building"):
			return {}
		# The subset is sorted, not the roster — same argument as
		# [archetype_upgrade_candidate], and the answer still has to be the
		# FIRST one by id, so the sort cannot be dropped entirely.
		var ids: Array[String] = []
		for id: Variant in sim.buildings:
			var candidate: Building = sim.buildings[String(id)]
			if String(candidate.archetype) == archetype:
				ids.append(String(id))
		ids.sort()
		for id: Variant in ids:
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level >= b.max_level:
				continue
			var preview: Dictionary = sim.cmd_upgrade_building(sim_id, true)
			if bool(preview["ok"]):
				continue
			var blockers: Array = (preview.get("payload", {}) as Dictionary).get(
					"blockers", [])
			if blockers.is_empty():
				continue
			var next_stats: Dictionary = sim.catalog.stats(archetype, b.level + 1)
			# WHICH component is short, asked of the grid rather than guessed:
			# `can_upgrade_power` already names it (`at`) and the building
			# preview does not forward it. Empty when power is not the blocker.
			var at := ""
			var delta_kw := float(next_stats.get("power_demand_kw", 0.0)) \
					- float(b.stats.get("power_demand_kw", 0.0))
			if String(blockers[0]) == "E_POWER_HEADROOM":
				at = String(sim.power_headroom(sim_id, delta_kw).get("at", ""))
			return {"sim_id": sim_id, "tile": b.origin,
					"blocker": String(blockers[0]),
					"cost": int((preview.get("payload", {}) as Dictionary).get("cost", 0)),
					"power_at": at,
					"transformer_level": Api.transformer_level_for(
							float(next_stats.get("power_demand_kw", 0.0)))}
		return {}


	## The smallest doc 04 §2.2 transformer rung that can carry `kw` and still sit
	## under the 90 % headroom `PowerGrid.can_upgrade_power` demands. Clamped to
	## the top rung: buying too small is a wasted $500, buying nothing is a wall.
	static func transformer_level_for(kw: float) -> int:
		var ladder: Array = PowerGrid.CAPACITY[&"transformer"]
		var want := kw * 1.15 / 0.90
		for i in ladder.size():
			if float(ladder[i]) >= want:
				return i + 1
		return ladder.size()

	## `relief_spot`, aimed at ONE building instead of at the hottest transformer
	## in the city. Same ring scan, same `relieved_kw > 0` gate, same determinism.
	func relief_spot_near(centre: Vector2i, level: int, radius: int) -> Vector2i:
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var tile := centre + Vector2i(dx, dz)
				var quote: Dictionary = sim.cmd_place_grid_component(
						"transformer", tile, level, true)
				if not bool(quote["ok"]):
					continue
				if float((quote["payload"] as Dictionary).get("relieved_kw", 0.0)) <= 0.0:
					continue
				return tile
		return Vector2i(-1, -1)

	## Is there a substation with a free feeder slot (doc 04 §2.2's 2/3/4/6/8
	## ladder)? When there is not, more copper is not buyable at any price and
	## the answer is a $15,000 substation instead.
	func has_feeder_slot() -> bool:
		for sim_id in Api._sorted(sim.buildings):
			if not sim.grid.has_component(String(sim_id)):
				continue
			if String(sim.grid.component(String(sim_id))["kind"]) != "substation":
				continue
			if int(sim.grid.feeder_slots(String(sim_id))["free"]) > 0:
				return true
		return false

	## Doc 07's ambient, as the grid tick reads it.
	func _ambient() -> float:
		return float(sim.weather.env_for_grid().get("t_ambient_c", 25.0))

	## The same command's read-only quote. Costs no money and no log line — the
	## price probe `Experiments.transformer_payback` reads the $ figure from here.
	func grid_quote(kind: String, tile: Vector2i, level: int = 1) -> Dictionary:
		if not has_verb("cmd_place_grid_component"):
			return CommandQueue.fail(&"E_NO_VERB")
		return sim.cmd_place_grid_component(kind, tile, level, true)

	## What a doc 05 component costs, without needing a tile to ask at. Doc 03
	## prices it off the variant's cost ratio and the difficulty's `M_build`, and
	## none of that depends on where it lands — which is what lets a saving agent
	## price the purchase before it has found a site for it.
	func water_quote(kind: String, level: int = 1) -> int:
		if not has_verb("cmd_place_water_component"):
			return 0
		var rules: Dictionary = sim.water.data.placeable_rules(kind)
		return sim.econ_curves.water_component_build_cost(
				sim.water.data.variant_cost_ratio(StringName(kind),
						String(rules.get("subtype", ""))),
				level, float(sim.treasury.difficulty().get("M_build", 1.0)))

	## Calls a verb only when its signature can accept what we pass: REQUIRED
	## arity no greater than the argument count, and enough parameters in total.
	## A verb that lands with a different shape is recorded as
	## `E_VERB_SIGNATURE` and never called again in this run — the harness must
	## degrade, never crash, when the command layer moves under it.
	func _optional(verb: String, arity: int, args: Array, subject: String) -> Dictionary:
		if not has_verb(verb):
			return CommandQueue.fail(&"E_NO_VERB")
		if int(verbs[verb]["required"]) > arity or int(verbs[verb]["args"]) < arity:
			_disabled[verb] = true
			return _log(verb, subject, CommandQueue.fail(&"E_VERB_SIGNATURE"), {})
		var result: Variant = sim.callv(verb, args)
		if not (result is Dictionary) or not (result as Dictionary).has("ok"):
			_disabled[verb] = true
			return _log(verb, subject, CommandQueue.fail(&"E_VERB_CONTRACT"), {})
		return _log(verb, subject, result, {})

	# --- read-only city queries a strategy is allowed to make ---------------

	## Buildings worth maintaining, worst condition first, sim_id tie-break.
	## `damaged` state ranks with its condition, which is where it belongs: a
	## damaged building IS a low-condition building (doc 02 §2.12).
	func maintenance_queue(threshold: float) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for id in _sorted(sim.buildings):
			var b: Building = sim.buildings[id]
			if b.state != &"active" and b.state != &"damaged":
				continue
			# Doc 02 §2.6a (doc 93 §Y1): private stock keeps itself up and
			# `cmd_repair_building` refuses it, so an agent that queued it would
			# spend its one repair action per tick being told no and would never
			# reach the plant. Skipping it here is not the agent being told the
			# answer — it is the agent reading the same `owner_maintained` flag
			# the building panel reads to decide whether to draw the row at all.
			if b.owner_maintained:
				continue
			if b.condition >= threshold:
				continue
			out.append({"sim_id": String(id), "condition": b.condition,
					"state": String(b.state)})
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a["condition"]), float(b["condition"])):
				return float(a["condition"]) < float(b["condition"])
			return String(a["sim_id"]) < String(b["sim_id"]))
		return out

	## The lowest condition standing in the city, 1.0 when nothing has aged.
	func min_condition() -> float:
		var lowest := 1.0
		for id in sim.buildings:
			var b: Building = sim.buildings[id]
			if b.state == &"destroyed":
				continue
			lowest = minf(lowest, b.condition)
		return lowest

	## Owned blocks that have not started the doc 09 §2.3 pipeline — a block the
	## player paid for and forgot is dead capital, so a land-buying strategy has
	## to sweep for them.
	func undeveloped_owned_blocks() -> Array[String]:
		var out: Array[String] = []
		for id in sim.world.block_ids_sorted():
			var block: LandBlock = sim.world.block(String(id))
			if block != null and block.is_owned() \
					and block.development_state == &"UNDEVELOPED":
				out.append(String(id))
		return out

	# --- bookkeeping --------------------------------------------------------

	## Doc 07 §2.7.7 (99-PA PA-26). Takes one preparation action for the storm
	## the city has been warned about. Refusals are recorded like every other
	## verb's, which is the point of driving it at all: `E_PREP_WINDOW` and
	## `E_NO_STORM` outnumbering `OK` in a run's reason-code table is how a
	## reader sees that the window is too narrow to hit.
	func storm_prep(action_id: String, target: Dictionary = {}) -> Dictionary:
		var result: Dictionary = sim.cmd_storm_prep_action(action_id, target)
		if bool(result["ok"]):
			storm_preps += 1
			storm_prep_spend += int((result["payload"] as Dictionary).get("cost", 0))
		return _log("cmd_storm_prep_action", action_id, result, {})

	func _log(verb: String, subject: String, result: Dictionary, extra: Dictionary) -> Dictionary:
		var reason := String(result.get("reason_code", ""))
		if reason == "":
			reason = "OK" if bool(result["ok"]) else "E_UNKNOWN"
		reason_codes[reason] = int(reason_codes.get(reason, 0)) + 1
		var entry := {"hour": hour, "verb": verb, "subject": subject,
				"ok": bool(result["ok"]), "reason": reason}
		for key in extra:
			entry[key] = extra[key]
		var payload: Dictionary = result.get("payload", {})
		if payload.has("cost"):
			entry["cost"] = int(payload["cost"])
		if payload.has("sim_id"):
			entry["sim_id"] = String(payload["sim_id"])
		actions.append(entry)
		return result

	static func _sorted(dict: Dictionary) -> Array:
		var keys := dict.keys()
		keys.sort()
		return keys


# ===========================================================================
# Strategies
# ===========================================================================

class Strategy extends RefCounted:
	func id() -> String:
		return "strategy"

	func describe() -> String:
		return ""

	## Called at the TOP of game-hour `hour` (0-based), before that hour runs.
	func act(_api: Api, _hour: int) -> void:
		pass

	## **The game-minute hook, and the one thing in this harness that costs
	## something to leave switched on** (RR-86).
	##
	## Every agent before Wave 15 acted once a game-hour, so `Runner` could
	## advance the sim an hour at a time. Doc 06 §2.16's opportunities live for
	## two to four game-hours and are drawn once a game-MINUTE, so an agent that
	## taps has to be given the minute — and slicing the fine advance into sixty
	## calls is sixty times the loop overhead for every agent that does not.
	##
	## So it is opt-in and `false` is the default: `Runner` slices only when the
	## strategy asks. **The slice is bit-identical to the whole hour** —
	## `advance_hours(1.0)` is `advance_fine_n(240)`, and sixty
	## `advance_hours(1.0/60.0)` are sixty `advance_fine_n(4)` on the same tick
	## loop — which `tests/test_playtest_harness.gd` asserts on the state hash
	## rather than on this paragraph.
	func wants_game_minutes() -> bool:
		return false

	## Called once per game-minute, after that minute's four fine ticks have run.
	## `minute` counts from 0 at the start of the run. **Coarse runs never call
	## it**: doc 06 §2.16's spawner draws nothing on the coarse step, so there
	## would be nothing to answer and the call would only cost time.
	func tick_minute(_api: Api, _minute: int) -> void:
		pass


## The control. Issues nothing; measures whether the founding city stands up on
## its own, and what the untouched treasury/stability curves look like.
class DoNothing extends Strategy:
	func id() -> String:
		return "do_nothing"

	func describe() -> String:
		return "issues no commands — the founding-city control curve"


## Spends everything, always. Places the most population-dense revenue building
## it can afford, upgrades whenever the gate is clear, keeps no reserve — and
## **never buys infrastructure**: no transformer, no repair, no land. That is
## the experiment. When the served ground runs out this agent walks into
## `E_UNSERVED` on purpose (`WALL_PROBE_PERIOD`), so the report can count how
## long the founding grid holds a max-growth player and what it costs to be
## stopped by it. If the city stays profitable through that wall, growth is
## unopposed and doc 03 has a problem.
class GreedyGrowth extends Strategy:
	const MAX_ACTIONS_PER_HOUR := 3
	const CATEGORIES: Array[String] = ["residential", "commercial", "industrial"]
	## A greedy agent saves for the densest thing it can eventually buy — but a
	## bounded wait, so a ranking it can never afford cannot freeze it.
	const MAX_SAVE_HOURS := 24
	## Once the served ground is gone, bang on the wall this often (game-hours)
	## rather than every hour: the reason-code histogram wants the signal, not
	## 500 identical rows.
	const WALL_PROBE_PERIOD := 6

	var _saving_since: int = -1
	var _wall_probe_hour: int = -1000

	func id() -> String:
		return "greedy_growth"

	func describe() -> String:
		return "max heads per dollar, zero reserve, buys no infrastructure ever"

	func act(api: Api, hour: int) -> void:
		for i in MAX_ACTIONS_PER_HOUR:
			if not _one_action(api, hour):
				return

	## One decision: the best *new build* and the best *upgrade* are scored on
	## the same axis — heads (population + jobs) bought per dollar — and the
	## winner is taken. Scoring upgrades on their DELTA is what stops a greedy
	## agent from simply carpeting the map in level-1 houses forever.
	func _one_action(api: Api, hour: int) -> bool:
		var ranked := _ranked_builds(api)
		if ranked.is_empty():
			return _take_best_upgrade(api)
		var top: Dictionary = ranked[0]
		if api.balance() < int(top["cost"]):
			if _saving_since < 0:
				_saving_since = hour
			if hour - _saving_since < MAX_SAVE_HOURS:
				return false  # hold the cash for the denser row
			top = {}
			for row in ranked:
				if api.balance() >= int(row["cost"]):
					top = row
					break
			if top.is_empty():
				return _take_best_upgrade(api)
		_saving_since = -1
		var upgrade := _best_upgrade(api)
		if not upgrade.is_empty() and float(upgrade["score"]) > float(top["score"]):
			return bool(api.upgrade(String(upgrade["sim_id"]))["ok"])
		var archetype := String(top["archetype"])
		var result := api.place(archetype)
		if bool(result["ok"]):
			return true
		# Out of served ground. Prove it against the command layer on a cooldown,
		# then fall back to monetising what already stands.
		if String(result["reason_code"]) == "E_NO_SITE" \
				and hour - _wall_probe_hour >= WALL_PROBE_PERIOD:
			_wall_probe_hour = hour
			api.place(archetype, true)
		return _take_best_upgrade(api)

	## Population + jobs per dollar, descending, id tie-break — the "growth per
	## dollar" ranking a min-maxing player would use. Affordability is NOT a
	## filter here; `_one_action` decides whether to buy or save.
	func _ranked_builds(api: Api) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for archetype in api.buildable(CATEGORIES):
			var cost := api.build_cost(archetype)
			if cost <= 0:
				continue
			out.append({"archetype": archetype, "cost": cost,
					"score": float(_heads(api, archetype, 1)) / float(cost)})
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a["score"]), float(b["score"])):
				return float(a["score"]) > float(b["score"])
			return String(a["archetype"]) < String(b["archetype"]))
		return out

	func _take_best_upgrade(api: Api) -> bool:
		var upgrade := _best_upgrade(api)
		if upgrade.is_empty():
			return false
		return bool(api.upgrade(String(upgrade["sim_id"]))["ok"])

	func _best_upgrade(api: Api) -> Dictionary:
		var best := {}
		for row in api.upgrade_candidates(CATEGORIES):
			var cost := int(row["cost"])
			if cost <= 0 or api.balance() < cost:
				continue
			var archetype := String(row["archetype"])
			var level := int(row["level"])
			var delta := _heads(api, archetype, level + 1) - _heads(api, archetype, level)
			var score := float(delta) / float(cost)
			if best.is_empty() or score > float(best["score"]) + 1e-12:
				best = {"sim_id": String(row["sim_id"]), "score": score, "cost": cost}
		return best

	static func _heads(api: Api, archetype: String, level: int) -> int:
		var stats: Dictionary = api.sim.catalog.stats(archetype, level)
		return int(stats.get("population", 0)) + int(stats.get("jobs", 0))


## Buys the city's bones before its income, in this order every hour:
## repair → **grid ahead of growth** → **land** → civic upgrade → civic build →
## floorspace out of deep surplus.
##
## Pass 2's rewrite is the middle two rungs. This agent does not wait to be
## stopped by `E_UNSERVED`: it keeps a standing stock of served-but-empty ground
## (`GRID_LEAD_TILES`) by buying transformers before it needs them, and it buys
## the next land block whenever the war chest can carry the purchase and the
## development bill behind it. That is what "infrastructure first" has to mean
## now that the verbs exist — the opposite pole from `greedy_growth`, which
## buys none of it.
class InfrastructureFirst extends Strategy:
	## Deep enough to never miss a payroll, shallow enough that the strategy
	## actually buys something out of the founding $25,000 — the point of this
	## agent is the ORDER it spends in, not hoarding.
	const RESERVE := 8_000
	## Revenue floorspace only out of a much deeper surplus, so the civic ladder,
	## the grid and the land bill always outrank it. Pass 2 lowered this from
	## $40k: with land and grid now buyable, an agent that never grows never
	## needs either, and a strategy that cannot exercise its own thesis measures
	## nothing.
	const REVENUE_RESERVE := 25_000
	const INFRA: Array[String] = ["service", "utility"]
	const REVENUE: Array[String] = ["residential", "commercial", "industrial"]
	## One of each civic archetype per this many residents — the "keep the city
	## covered as it grows" reading of infrastructure-first. Coverage radii are
	## still read by nothing (doc 92 pass 1, F-6), so headcount remains the only
	## honest proxy a strategy can size against.
	const CIVIC_PER_POPULATION := 100
	## Repair anything that has lost this much condition, worst first.
	const REPAIR_THRESHOLD := 0.90

	## Ahead-of-growth rule: every owned+READY block holds at least this many
	## served, buildable, empty tiles. Below it, buy another transformer for that
	## block. An L1 tap covers a 7×7 patch, so one purchase moves the number by
	## tens — the threshold is a trigger, not a target.
	const GRID_LEAD_TILES := 24
	## Attempts are cheap but not free — a verb that answers `E_FUNDS` every
	## hour would drown the action log.
	const GRID_ATTEMPT_COOLDOWN := 4
	## A transformer plus its lateral is order $1k (doc 03 §2.13(b)); this is the
	## working balance below which even that waits for the reserve.
	const GRID_ATTEMPT_FLOOR := 2_000

	## Land: doc 09 §2.5's purchase plus doc 03 §2.8's six development phases.
	## The affordability test is against the purchase AND the estimate behind it,
	## so the agent never strands a block it cannot develop — and when it cannot
	## yet afford both it SAVES rather than spending the difference on
	## floorspace. Without that, an agent whose reserve is smaller than a land
	## bill can never buy land at all, which is a bug in the agent, not a
	## finding about the price.
	const LAND_COOLDOWN := 12
	const LAND_IDLE := 0
	const LAND_ACTED := 1
	const LAND_SAVING := 2
	## Rhythm: grid and fill the land you bought before saving for the next
	## block. Without it the agent saves for a purchase every single hour and
	## never builds anything, which measures the land price and nothing else.
	const BUILDINGS_PER_BLOCK := 24

	# --- Wave 11: the TRUNK, which is a different decision from the tap -------
	##
	## Doc 92 §17.3 measured the ceiling no transformer rung can lift: every kW
	## the city draws runs through doc 09 §2.9.5's two class-1 feeders, and the
	## demand crosses them at ~410 buildings. `Balanced` has watched that number
	## since Wave 6; this agent did not, which made "infrastructure first" a
	## claim about taps only. Doc 93 §J2 gave `route_feeder` a card on the build
	## sheet, so the brief and the door now agree and the rule is here.
	##
	## **Every constant is `Balanced`'s, deliberately.** The trigger is doc 04
	## §5.10's WARNING band — the only authored statement in the project of how
	## loaded is too loaded — and the class, the cooldown and the floor are the
	## figures §17.3's follow-up fitted. Two agents watching one number with two
	## thresholds would make the matrix unreadable.
	const FEEDER_RELIEF_RATIO := PowerGrid.OVERLAY_WARNING_R
	const FEEDER_CLASS := 2
	const FEEDER_COOLDOWN := 6
	const FEEDER_ATTEMPT_FLOOR := 10_000

	var _grid_attempt_hour: int = -1000
	var _land_attempt_hour: int = -1000
	var _feeder_hour: int = -1000

	func id() -> String:
		return "infrastructure_first"

	func describe() -> String:
		return "repairs, buys trunk and grid ahead of growth and land ahead of both"

	func act(api: Api, hour: int) -> void:
		if _repair_something(api):
			return
		if _relieve_trunk(api, hour):
			return
		if _extend_grid(api, hour):
			return
		var land := _land_move(api, hour)
		if land == LAND_ACTED:
			return
		var infra_upgrades := api.upgrade_candidates(INFRA)
		if not infra_upgrades.is_empty() \
				and api.balance() - int(infra_upgrades[0]["cost"]) >= RESERVE:
			api.upgrade(String(infra_upgrades[0]["sim_id"]))
			return
		var target := _next_infra(api)
		if target != "" and api.balance() - api.build_cost(target) >= RESERVE:
			api.place(target)
			return
		if land == LAND_SAVING:
			return  # every spare dollar is earmarked for the next block
		# Surplus above the reserve buys floorspace, cheapest first, so the
		# civic ladder always outranks it.
		var revenue := _cheapest(api, REVENUE)
		if revenue != "" and api.balance() - api.build_cost(revenue) >= REVENUE_RESERVE:
			api.place(revenue)

	## Doc 93 §B's headline verb, used the way the fantasy intends. Two triggers,
	## in this order:
	##
	## 1. **New land has no grid.** A block bought and developed through doc 09
	##    §2.3 arrives with a utility corridor to its centre and no transformer,
	##    so all 256 of its tiles answer `E_UNSERVED`. Grid goes in before
	##    anything else does — that is what "ahead of growth" means here.
	## 2. **The served stock is running down.** Below `GRID_LEAD_TILES` empty
	##    served tiles anywhere in the city, buy the tap that lights the most
	##    dark ground, before the wall is actually hit.
	func _extend_grid(api: Api, hour: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if hour - _grid_attempt_hour < GRID_ATTEMPT_COOLDOWN:
			return false
		if api.balance() < RESERVE + GRID_ATTEMPT_FLOOR:
			return false
		var tile := api.grid_shortfall_tile(GRID_LEAD_TILES)
		if tile.x < 0:
			return false
		_grid_attempt_hour = hour
		return bool(api.place_grid_component("transformer", tile)["ok"])

	## Doc 04 §4's `route_feeder`, ahead of the tap for the same reason the tap is
	## ahead of the building: a saturated trunk makes every transformer behind it
	## useless, and §2.5's relay opens at r = 1.05.
	##
	## **When every slot is full this rule does nothing, on purpose.** The answer
	## to a full substation is doc 04 §2.2's ladder — a $15,000 substation, or an
	## upgrade of the one that is there — and since Wave 6 a completed
	## `substation` shell IS its grid node (doc 04's `node_shells`), so the civic
	## ladder below can already buy the fix on its own schedule. `Balanced` has a
	## dedicated stand-down for the starved state (`_trunk_starved`, which holds
	## its land fund); this agent has no land fund to hold, so it simply falls
	## through to its next rung rather than growing a second savings rule.
	func _relieve_trunk(api: Api, hour: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if api.feeder_peak_ratio() < FEEDER_RELIEF_RATIO:
			return false
		if hour - _feeder_hour < FEEDER_COOLDOWN:
			return false
		if not api.has_feeder_slot():
			return false
		if api.balance() < RESERVE + FEEDER_ATTEMPT_FLOOR:
			return false
		var target := api.hot_feeder_target()
		if target.x < 0:
			return false
		_feeder_hour = hour
		return bool(api.route_feeder(target, FEEDER_CLASS)["ok"])

	## Doc 09 §2.5 + §2.3. Three outcomes: finish paying for a block already
	## bought but never started, buy the next one, or declare that the treasury
	## is saving toward it. The affordability test covers the purchase, the
	## development estimate and the reserve together.
	func _land_move(api: Api, hour: int) -> int:
		if not api.has_verb("cmd_buy_block"):
			return LAND_IDLE
		for block_id in api.undeveloped_owned_blocks():
			if hour - _land_attempt_hour < LAND_COOLDOWN:
				return LAND_IDLE
			_land_attempt_hour = hour
			return LAND_ACTED if bool(api.start_development(block_id)["ok"]) else LAND_IDLE
		if api.placed < (api.blocks_bought + 1) * BUILDINGS_PER_BLOCK:
			return LAND_IDLE  # fill what you already own first
		var candidate := api.purchasable_block()
		if candidate == "":
			return LAND_IDLE
		# Preview: free, and the only honest source of the doc 03 §2.7 price.
		var quote: Dictionary = api.sim.cmd_buy_block(candidate, true)
		if not bool(quote["ok"]):
			return LAND_SAVING  # E_FUNDS on the preview is a savings target
		var payload: Dictionary = quote["payload"]
		var bill := int(payload.get("price", 0)) + int(payload.get("development_estimate", 0))
		if api.balance() - bill < RESERVE:
			return LAND_SAVING
		if hour - _land_attempt_hour < LAND_COOLDOWN:
			return LAND_IDLE
		_land_attempt_hour = hour
		return LAND_ACTED if bool(api.buy_block(candidate)["ok"]) else LAND_IDLE

	func _repair_something(api: Api) -> bool:
		if not api.has_verb("cmd_repair_building"):
			return false
		var queue := api.maintenance_queue(REPAIR_THRESHOLD)
		if queue.is_empty():
			return false
		return bool(api.repair(String(queue[0]["sim_id"]))["ok"])

	## The civic archetype the city is shortest of, counted against how many the
	## city already has. Deterministic: sorted ids, first shortfall wins.
	func _next_infra(api: Api) -> String:
		var have := {}
		for id in api.sim.buildings:
			var archetype := String((api.sim.buildings[id] as Building).archetype)
			have[archetype] = int(have.get(archetype, 0)) + 1
		var want := 1 + api.sim.population.city_population / CIVIC_PER_POPULATION
		for archetype in api.buildable(INFRA):
			if int(have.get(archetype, 0)) < want:
				return archetype
		return ""

	func _cheapest(api: Api, categories: Array) -> String:
		var best := ""
		var best_cost := 0
		for archetype in api.buildable(categories):
			var cost := api.build_cost(archetype)
			if cost <= 0:
				continue
			if best == "" or cost < best_cost:
				best = archetype
				best_cost = cost
		return best


## Competent-but-not-optimal play, which is what doc 03 §2.12's pacing model is
## modelled on: hold a reserve of one game-day of gross expense (floor $12k),
## grow residential and commercial at a 2:1 ratio, upgrade what is already
## standing before adding more, keep a station roster sized to the city, keep the
## city in repair out of a maintenance budget, and expand outward out of a land
## budget.
##
## **Wave-4 rebalance (doc 92 §13.1).** Pass 2's version was a single-action
## ladder with a repair-first early return; once doc 02 §2.6 wear went live the
## maintenance queue was never empty, so the agent spent half its action budget
## repairing and stopped growing — 153 buildings and $480,480 of idle cash in 21
## game-days. It now runs a **maintenance ladder and a growth ladder in the same
## game-hour**, each on its own budget line, and builds a 325-building city while
## holding its worst building at the repair threshold. Both variants below
## inherit all of it, so they are still the same agent with one field changed.
##
## Two knobs on this class are the whole design of pass 2's new strategies.
## `tax_squeezer` and `disaster_neglect` are this agent with ONE of them moved,
## so any difference in their curves is attributable to that knob and nothing
## else — a controlled pair, not two more bots.
class Balanced extends Strategy:
	## **The reserve floor is a FRACTION of the founding purse, not a constant**
	## (doc 92 §29.5 ranked item 4, closed in §32.4).
	##
	## Pass 2 authored it as a flat **$12,000**, and on `standard` — the only
	## preset that existed then — that one number is two things at once: about one
	## founding game-day of expense ($12,100) *and* 48 % of the founding purse
	## ($25,000). Only one of the two travels: on `crisis` the flat floor IS the
	## entire founding purse, so `spare = balance − reserve` is zero on game-hour
	## 0 and the agent cannot even open its ladder. An agent whose reserve is a
	## constant cannot measure a difficulty that scales the purse.
	##
	## `12,000 / 25,000 = 0.48` reproduces `standard` **to the dollar** — the
	## constant is not retired, it is re-expressed in the units it was always in —
	## and it scales with `starting_treasury` on the other three: casual $16,800,
	## hard $8,640, crisis $5,760.
	##
	## **What this does NOT fix, said here so the next reader does not re-derive
	## it.** Doc 92 §29.5(a) step 3 blamed this floor for `balanced` placing zero
	## buildings in 21 game-days on `crisis`. It was the other term:
	## `operating_reserve()` is `max(floor, one game-day of expense)`, and on
	## crisis the payroll was $17,968 against a $12,000 purse, so the floor never
	## entered the maximum. What unfroze the agent was doc 93 §N1 taking `M_exp`
	## off `E_roads_repair`, which moved crisis's founding net −$18.70 →
	## +$44.47/gh. Doc 92 §32.4 measures all three arms.
	const RESERVE_FLOOR_FRACTION := 0.48
	const RESERVE_DAYS_OF_EXPENSE := 1.0
	const RESIDENTIAL_PER_COMMERCIAL := 2
	const REVENUE: Array[String] = ["residential", "commercial", "industrial"]
	const INFRA: Array[String] = ["service", "utility"]
	## Upgrades are cheaper per point of yield than new floorspace, so take one
	## whenever the reserve allows — but never more than one action per hour.
	const UPGRADE_HEADROOM := 2.0

	## Expansion: a competent player buys the next block when the war chest can
	## absorb both the purchase and the development bill (doc 03 §2.7/§2.8).
	##
	## Pass 2 read that as a flat $80,000 surplus and it worked only by accident:
	## the repair-first early return starved building, so the agent BANKED, and
	## gate 11 was met "by the money, not the map". With the Wave-4 rebalance the
	## same agent spends its surplus on floorspace and never sees $80k again —
	## measured, seed 1337, 21 game-days: **0 blocks bought, 0 `E_NO_SITE`**. So
	## expansion becomes a BUDGET LINE like maintenance: `LAND_BUDGET_SHARE` of
	## every settled net is set aside in a land fund (which `reserve()` counts, so
	## the growth ladder cannot spend it), the fund is capped at the quoted
	## all-in cost of the next block, and the purchase fires when the fund covers
	## it. Doc 92 F-8 measured that all-in at **$45k–$66k** per ring block, so a
	## 15 % line buys one roughly every 3–5 game-days at the mid-game net.
	const LAND_BUDGET_SHARE := 0.15
	const EXPAND_COOLDOWN := 24
	## How often the land quote is refreshed (game-hours). `cmd_buy_block`'s
	## preview walks doc 03 §2.7's seven-term price, so it is not a per-hour call.
	const LAND_QUOTE_PERIOD := 24

	## Maintenance (doc 02 §2.6): repair below this condition, worst first, and
	## give the civic roster a shed-proof priority class once (doc 04 §2.4).
	##
	## **0.80, FITTED, not chosen** (Wave-4 ruling 2; full derivation in doc 92
	## §13.2). Two ruled targets ride on this number and on `decay_per_hour`, and
	## they separate cleanly:
	##
	##     repair $/gh      = Σ capital_b × decay_b × REPAIR_COST_PER_CAPITAL  ← RATE
	##     repair trips/day = Σ decay_b × 24 / (1 − threshold)                 ← THRESHOLD
	##
	## The money a maintaining city spends does not depend on the threshold at
	## steady state (a repair restores exactly what was lost, at a price linear in
	## the loss); only the trip count does, as `1/(1 − T)`. So the rate was pinned
	## first — measured at **11.5–17.2 % of net** for the 100–250-building city
	## this agent lives in, with a neglect arc of 2.2–2.8 game-weeks to doc 03's
	## `COND_FLOOR` and 3.9 to total decay, all three inside the ruled bands, so
	## **no `data/buildings.json` row moved** — and the trip count was then solved
	## with the threshold. Measured over three seeds at 21 game-days:
	##
	## | threshold | trips / game-day | repair spend / net | worst building at d21 |
	## |---|---|---|---|
	## | 0.90 (pass 2) | 11.5 | 11.8 % | 0.90 |
	## | 0.70 | 0.95 / 1.14 / 1.48 | 8.3 / 8.9 / 8.7 % | 0.70 |
	## | **0.80** | **4.4 / 5.1 / 5.1** | **12.1 / 11.4 / 11.3 %** | **0.79 / 0.80 / 0.78** |
	##
	## 0.80 is the only rung that lands both ruled targets at once. 0.90 is what
	## "more than one repair per game-hour to hold it" was measuring — the chore.
	const REPAIR_THRESHOLD := 0.80
	## Doc 92's ruled band for what a maintaining city spends on upkeep is 10–20 %
	## of net. This agent enforces the top of it as a HARD budget rather than
	## hoping: every settled game-hour credits `MAINT_BUDGET_SHARE × net` to a
	## maintenance purse, and a repair is taken only when the purse covers the
	## quote. Two things fall out of that and both are the point — the agent can
	## never repair itself insolvent, and a city whose income has collapsed stops
	## being able to afford maintenance, which is a failure mode rather than an
	## accounting rounding.
	const MAINT_BUDGET_SHARE := 0.20
	## An unbounded purse would defer nothing, so it is capped at one game-WEEK of
	## accrual. A shorter cap does not work and the reason is a price, not a
	## preference: the queue is worst-first and repair price is
	## `capital × damage_fraction × 0.85`, so its head is routinely a civic asset
	## — `WTR-1` at $45,000 of capital quotes ~$13k at the fitted threshold —
	## while one game-day of a mid-game allowance is ~$7k. Measured at
	## `MAINT_PURSE_DAYS` 1.0: **0 repairs in 21 game-days** and the worst
	## building at 0.34, because the purse could never reach the head of its own
	## queue.
	const MAINT_PURSE_DAYS := 7.0
	const CIVIC_PRIORITY := "ESSENTIAL"

	## **Grid ahead of growth (doc 92 pass-3 F-11, ruled Wave 5).**
	##
	## Pass 3's rule was reactive: buy ONE transformer when `candidate_site` has
	## nothing left, on an 8-game-hour cooldown. F-11 measured what that costs a
	## builder placing ~15 buildings a game-day — at 50 game-days, seed 1337, the
	## agent bought **one** transformer in the whole run, logged **1,215
	## `E_NO_SITE`** refusals, and spent two thirds of all building-time dark.
	##
	## Two things were wrong with it and they compound:
	##
	## 1. **The trigger was the wrong question.** It asked "is there a served 1×1
	##    tile anywhere in the city", which a founding core of 452 served tiles
	##    answers `yes` long after the block the agent is actually building on has
	##    run dry — and long after a freshly developed block, which doc 09 §2.3
	##    hands over with a utility corridor and *no transformer*, has 169 tiles
	##    that all answer `E_UNSERVED`.
	## 2. **It fired after the wall, not before it.** One tap per 8 game-hours is
	##    0.125 transformers/gh against 0.6 buildings/gh; an L1 tap opens at most
	##    49 tiles, so the rule could not keep up even if it never missed.
	##
	## The rule is now the one `infrastructure_first` has always used and the one
	## the ruling asks for: **every owned+READY block keeps `GRID_LEAD_TILES`
	## served, buildable, empty tiles**, checked per block (`grid_shortfall_tile`
	## early-outs the moment a block is comfortable), and the tap goes in before
	## the ground runs out. It is still a competent player, not an optimal one:
	## the lead is a buffer of a game-day or two of building, not a lit map.
	##
	## **40 is DERIVED from this agent's own build rate, not swept.** It builds
	## 12–15 buildings a game-day (~0.6/gh, measured), and a lead has to survive
	## the gap between the moment a block drops below it and the moment a tap is
	## both affordable and sited — several game-hours at the `GRID_COOLDOWN`
	## below, and longer whenever the operating reserve is tight. 40 tiles is
	## **~2.5 game-days of building**, and one purchase more than restores it: an
	## L1 tap opens ≤ 49 tiles at Chebyshev 3, an L2 ≤ 81 at Chebyshev 4. Smaller
	## leads are not wrong, they are just tighter; `infrastructure_first` runs 24
	## and is the deliberately more cautious pole.
	const GRID_LEAD_TILES := 40
	## Short, because the check is cheap and a new block needs several taps in a
	## row. Pass 3's 8 was sized for a rule that fired once per wall.
	const GRID_COOLDOWN := 2
	## A tap plus its lateral is order $1k (doc 03 §2.13(b)), so this is the
	## working balance below which even that waits for the operating reserve.
	const GRID_ATTEMPT_FLOOR := 2_000

	## **Which RUNG of the transformer ladder** (doc 92 F-11's second half).
	##
	## Lead alone was not enough, and the measurement says why. With
	## `GRID_LEAD_TILES` live the agent bought 43 L1 taps over 50 game-days and
	## still ran **62 % dark**, because an L1 transformer is doc 04 §8's
	## **50 kW** — and its own service radius is Chebyshev 3, a 49-tile patch. A
	## patch that size fills with ~15 kW of houses and stores per 5 tiles, so the
	## tap saturates at roughly a third of the ground it is allowed to serve, and
	## the surplus is SHED. Measured at day 30 of that run: 37 transformers, 11
	## of them over 100 %, worst **94 kW on a 50 kW rating (1.89×)**.
	##
	## L2 is the rung that matches the radius: **150 kW for $1,100** against L1's
	## 50 kW for $500 — 3× the capacity for 2.2× the price, and the only rung
	## whose rating a radius-4 patch cannot trivially exceed. A competent player
	## reads the ladder once and buys the rung that fits; this agent does the same.
	## Measured, 50 game-days, seed 1337 (lead 40 throughout):
	##
	## | rung | dark share, 50 gd | buildings | transformers | grid spend |
	## |---|---|---|---|---|
	## | L1 | 62.1 % | 804 | 43 | $36,790 |
	## | **L2** | **54.9 %** | 772 | 31 | $46,750 |
	##
	## At 50 game-days L2 buys a much healthier fleet for slightly fewer taps —
	## and the dark share barely moves, because by then the city is past a
	## ceiling neither rung can lift: doc 09's two class-1 feeders, 2,400 kW
	## total, which the demand crosses at ~410 buildings. See doc 92 §17.3 and
	## `tests/test_balance_gates.gd` gate 18b. Inside the 21-game-day pacing
	## horizon the rung is decisive: **8.70 % dark against pass 3's 25.72 %**.
	const GRID_LEVEL := 2

	# --- Wave 6: the TRUNK, which is a different decision from the tap --------
	##
	## Doc 92 §17.3 measured the ceiling the transformer rung above cannot lift:
	## every kW the city draws runs through doc 09 §2.9.5's two class-1 feeders,
	## 1,200 kW each, and the demand crosses them at ~410 buildings. The fleet
	## was fine, the substation sat at 45 % of 6 MVA and the plant was idle —
	## **the trunk was the whole of it**, and no verb could widen it.
	##
	## Wave 6 ships doc 04 §4's `route_feeder`, and this is the rule that uses
	## it. A competent player watches ONE number, the hottest feeder's load
	## ratio against its derated capacity, and buys trunk before it opens.
	##
	## **The trigger is doc 04's own, not a swept number.** §5.10 publishes the
	## overlay's three bands — `NORMAL` r < 0.75, `WARNING` 0.75 ≤ r < 0.95,
	## `CRITICAL` r ≥ 0.95 — and they are the only authored statement in the
	## project of how loaded is too loaded. A competent player buys when the
	## overlay changes colour, so this agent does.
	##
	## **A feeder is bought at WARNING** because its fix is slow: with every slot
	## full the answer is a $15,000 substation, an 8-game-hour build and then a
	## route, and §2.5's relay picks up at 1.05 and trips at r = 1.10 in
	## `120 / (1.10² − 1) = 571` game-seconds. From 0.75 this agent's demand
	## growth (~4–6 %/game-day, measured) leaves **five to eight game-days**;
	## from CRITICAL it would leave under two, which does not cover the build.
	const FEEDER_RELIEF_RATIO := PowerGrid.OVERLAY_WARNING_R
	## A routed feeder's load only exists after the next Pass A, and doc 04
	## §2.9's adoption takes what it can reach in ONE pass, so re-reading the
	## ratio sooner than this would buy a second run against a stale number.
	## Six game-hours also caps the rule at four purchases a game-day.
	const FEEDER_COOLDOWN := 6
	## Class 2 — 3,000 kW for doc 03 §2.13(b)'s $210/tile against class 1's
	## 1,200 kW for $110. **2.5× the capacity for 1.9× the price**, the same
	## shape of choice `GRID_LEVEL` makes on the transformer ladder, and doc 04
	## §6 ships no class 3.
	const FEEDER_CLASS := 2
	## A run to the middle of an overloaded circuit is order 30–50 tiles, so
	## ~$6k–$11k; this is the working balance below which even that waits.
	const FEEDER_ATTEMPT_FLOOR := 10_000

	# --- Wave 24: GENERATION, which is a third decision again -----------------
	##
	## **The wall this agent has always walked into, and nobody had looked**
	## (doc 92 §63.3, doc 93 §AW2). Wave 6 lifted doc 92 §17.3's trunk ceiling
	## and recorded that with the trunk fixed the ceiling *"moves to the
	## transformer"*. It moves once more, and the next one is the POOL: every
	## city in this project is founded with one `power_facility` at doc 04 §2.2's
	## L1 rating — **8,000 kW, and nothing else generates** — and no strategy in
	## this file has ever bought or upgraded generation.
	##
	## It was invisible because 8,000 kW is a long way off for a poor city, and
	## it is invisible in gate 18b's headline number for a sharper reason: the
	## gate averages a dark share over 50 game-days, and the pool goes short at
	## the very END of that window. Measured at the Wave-24 fork with
	## `tools/probe_dark.gd`, seed 1337, the SHIPPED Wave-22 grant table:
	##
	## | game-day | 20 | 30 | 40 | 45 | **50** |
	## |---|---|---|---|---|---|
	## | dark % that day | 0.08 | 3.31 | 4.63 | 6.24 | **15.55** |
	## | demand kW | 2,108 | 3,229 | 4,591 | 5,729 | **9,227** |
	## | supply kW | 8,000 | 8,000 | 8,000 | 8,000 | **8,000** |
	## | buildings orphaned by a shed circuit | 0 | 0 | 0 | 0 | **166** |
	##
	## The 50-game-day mean of that column is 5.99 %, which is the number gate
	## 18b passes on. **The gate was already standing on top of a wall it could
	## not see**, and on Wave 24's money the city reaches the same wall on
	## game-day ~33 instead of ~46, which is what turns 5.99 % into 37.60 %.
	##
	## Not one tile was unattached on either arm; not one transformer was
	## unparented; not one transformer was CRITICAL. **The distribution grid the
	## agent buys is correct and the city simply has no power.**
	##
	## So this rule is the same family as Wave 6's two — *a purchase the agent
	## never makes* — one level further up, and it is placed FIRST in the growth
	## ladder because no number of feeders relieves a pool that is short.
	##
	## **The trigger is doc 04 §5.10's own band and not a swept number**, exactly
	## like `FEEDER_RELIEF_RATIO`: a competent player buys generation when the
	## power panel's pool reading goes amber. `capacity_summary().load_ratio` is
	## the whole-system reading doc 04 already publishes for it.
	const GENERATION_RELIEF_RATIO := PowerGrid.OVERLAY_WARNING_R
	## The one archetype doc 02 sells that generates (`power_plant_gas` in doc
	## 03's naming; `data/building_economy.json` carries the alias table).
	const GENERATION_ARCHETYPE := "power_facility"

	## **The hotspot rule**, and it is the same reading one level down.
	##
	## With the trunk fixed, doc 92 §17.3's ceiling moves to the transformer —
	## measured on the Wave-6 sim, seed 1337, 50 game-days: feeders end at 26.8 %
	## aggregate and a 0.86 peak, while the transformer fleet has **13 of 51 past
	## 100 %** and a worst of r = 2.32. That is not a rating problem, it is a
	## *purchase* the agent never makes: `_lead_grid` buys a tap when a block runs
	## out of SERVED GROUND, and an overloaded transformer sitting in the middle
	## of ground that is fully served never triggers it.
	##
	## Doc 04 §2.9 sells the answer as "parallel transformer on one service
	## group", and Wave 6 makes it real (`PowerGrid.adopt_buildings`). This rule
	## buys it — and buys it at **CRITICAL**, not at WARNING like the feeder,
	## because the fix lands inside one command: a tap is placed and adopts its
	## share in the same game-hour, so there is nothing to get ahead of. Waiting
	## for red is also what stops the rule from becoming a treadmill — measured
	## at WARNING on the same seed it bought **116 transformers for $153,830** and
	## left the fleet 20.7 % loaded, which is a city paying to over-build the one
	## thing that was no longer its problem.
	const HOTSPOT_RATIO := PowerGrid.OVERLAY_CRITICAL_R
	const HOTSPOT_RADIUS := 3
	const HOTSPOT_COOLDOWN := 2

	## KNOB 1 — maintenance. `disaster_neglect` sets this false and changes
	## nothing else: no repair, no priority class, no transformer. Everything it
	## builds, it builds exactly as `balanced` would.
	var maintains: bool = true
	## KNOB 2 — the tax detent to hold, or −1 to leave the rate at the founding
	## `TAX_RATE_BASE` 0.09. `tax_squeezer` sets the top detent and changes
	## nothing else.
	var tax_target: int = -1

	var _residential_streak: int = 0
	var _civic_at_level: int = -1
	var _last_expense_per_hour: float = 0.0
	var _expand_hour: int = -1000
	var _grid_hour: int = -1000
	var _feeder_hour: int = -1000
	var _hotspot_hour: int = -1000
	## Set while the trunk is past `FEEDER_RELIEF_RATIO` and every feeder slot in
	## the city is full — i.e. while the ONE purchase that would fix it is a
	## substation the agent cannot yet afford. It stands the land fund down (see
	## `reserve`) and holds the expansion ladder, and nothing else.
	var _trunk_starved: bool = false
	var _tax_hour: int = -1000
	var _priorities_set: bool = false
	## Doc 03 §2.10-shaped maintenance allowance, in dollars. Credited every
	## game-hour from the settled net, spent by `_maintain`, capped at
	## `MAINT_PURSE_DAYS` game-days of accrual against `_net_ema`.
	var _maint_purse: float = 0.0
	var _net_ema: float = 0.0
	## The land fund and the cached quote it is saving toward.
	var _land_fund: float = 0.0
	var _land_target: float = 0.0
	var _land_block: String = ""
	var _land_quote_hour: int = -1000
	## `RESERVE_FLOOR_FRACTION × starting_treasury`, resolved once from the live
	## city on the first game-hour. Read off `Treasury.difficulty()` rather than
	## `Difficulty` directly, because the treasury's row is the one the city was
	## actually FOUNDED on (doc 93 §K1) — it is the same dictionary a save
	## restores, so a strategy driving a loaded city gets the right purse.
	var _reserve_floor: int = 0

	func id() -> String:
		return "balanced"

	func describe() -> String:
		return "2:1 residential:commercial, 1-day reserve, upgrade-first, " \
				+ "budget-gated maintenance, station roster, land fund"

	func note_expense(expense_per_hour: float) -> void:
		_last_expense_per_hour = expense_per_hour

	## The founding purse this city was handed, cached on first read. `Factory`
	## constructs a `Strategy` before any `CitySim` exists, so this cannot live in
	## `_init`; every `act()` in this class hierarchy calls it first, before
	## anything reads `operating_reserve()`.
	func note_founding_purse(api: Api) -> void:
		if _reserve_floor > 0:
			return
		var purse := float(int(api.sim.treasury.difficulty()
				.get("starting_treasury", 0)))
		_reserve_floor = int(RESERVE_FLOOR_FRACTION * purse)

	## One game-day of gross expense, floored — the payroll this agent will not
	## touch. `reserve()` adds the land fund on top so the growth ladder cannot
	## spend money that is already earmarked for the next block.
	func operating_reserve() -> int:
		return maxi(_reserve_floor,
				int(RESERVE_DAYS_OF_EXPENSE * 24.0 * _last_expense_per_hour))

	func reserve() -> int:
		# The land fund is earmarked money the growth ladder may not touch —
		# EXCEPT while the city's trunk is starved, when the next block is the
		# last thing it needs and the $15,000 substation is the first.
		return operating_reserve() + (0 if _trunk_starved else int(_land_fund))

	## Wave-4 rebalance (ruling 1). Pass 2's `act` was a single-action ladder with
	## a repair-first early return, and doc 92 pass 2 / the Wave-3 report both
	## measured what that costs: once doc 02 §2.6 wear is live the maintenance
	## queue is never empty, so the early return spent roughly half of every
	## game-hour's action budget on repairs and the "competent" agent stopped
	## growing — it banked instead. That is a harness artifact standing in front
	## of a design question, and it made `value created` reward the agent that let
	## the city rot (see `tests/test_balance_gates.gd`'s header).
	##
	## The fix is that a competent player does BOTH in the same game-hour. This
	## `act` now runs two independent ladders:
	##
	##   1. **maintenance**, budget-gated — at most one repair, paid out of a
	##      purse that accrues `MAINT_BUDGET_SHARE` of the settled net;
	##   2. **growth**, unchanged from pass 2 — expand → unwall → civic → upgrade
	##      → floorspace, out of the surplus above the reserve.
	##
	## Neither starves the other, the maintenance spend is bounded by the ruled
	## 10–20 % band by construction, and `disaster_neglect` still differs from
	## this agent in exactly one field.
	func act(api: Api, hour: int) -> void:
		# The purse before anything reads the reserve off it.
		note_founding_purse(api)
		# Policy first: it is free (doc 03 prices no rate change beyond its
		# consequences) and it must be in force before the first settlement the
		# report reads.
		if _hold_tax(api, hour):
			return
		if maintains:
			_credit_maintenance(api)
			if not _set_civic_priorities(api):
				_maintain(api)
		_credit_land(api, hour)
		_grow(api, hour)

	## Layer 1 — the maintenance ladder. One repair at most, worst condition
	## first, only below `REPAIR_THRESHOLD`, only when the purse covers the quote.
	##
	## The scan walks DOWN the worst-first queue instead of stopping at its head,
	## and that is not a nicety: repair price is `capital × damage_fraction ×
	## REPAIR_COST_PER_CAPITAL`, so the worst building is usually also the dearest,
	## and a head-only budget gate head-of-line blocks forever on one L4 tower
	## while forty cheap houses rot behind it. Bounded at `MAINT_SCAN` quotes so
	## the per-hour cost stays flat in city size.
	const MAINT_SCAN := 24

	func _maintain(api: Api) -> bool:
		if not api.has_verb("cmd_repair_building"):
			return false
		var queue := api.maintenance_queue(REPAIR_THRESHOLD)
		for i in mini(queue.size(), MAINT_SCAN):
			var sim_id := String((queue[i] as Dictionary)["sim_id"])
			var cost := float(api.repair_quote(sim_id))
			if cost > _maint_purse:
				continue
			if not bool(api.repair(sim_id)["ok"]):
				continue
			_maint_purse -= cost
			return true
		return false

	## `MAINT_BUDGET_SHARE` of the last settled game-hour's net, capped at
	## `MAINT_PURSE_DAYS` game-days of accrual. A loss-making hour credits
	## nothing — maintenance is bought out of income, never out of the credit line.
	##
	## The cap is sized against a SMOOTHED net, not the instantaneous one. Hourly
	## net is spiky (doc 03 bills construction-completion hours and storm hours
	## very differently), and capping against a single bad hour collapses the purse
	## to nothing and strands the queue — measured: threshold 0.70 with an
	## instantaneous cap spent 4.9 % of net and still let the worst building reach
	## 0.34 in three game-weeks.
	const MAINT_NET_EMA := 0.05  # ~20-game-hour horizon

	func _credit_maintenance(api: Api) -> void:
		var net := api.last_net()
		_net_ema += (net - _net_ema) * MAINT_NET_EMA
		if net > 0.0:
			_maint_purse += MAINT_BUDGET_SHARE * net
		var cap := MAINT_BUDGET_SHARE * MAINT_PURSE_DAYS * 24.0 * maxf(0.0, _net_ema)
		_maint_purse = minf(_maint_purse, cap)

	## What civic building the city is short of, or "" when the roster is right.
	##
	## Pass 2 built ONE civic building per city level and doc 92 pass 2 costed it
	## as a pure `station_upkeep` line, because `FleetSystem` never re-read the
	## roster. Doc 92 F-3's fix (C-50, live in Wave 3) made a finished station
	## into response capacity, and this is the strategy half of that ruling: a
	## competent player buys engines as the city grows, and the agent that does
	## not walks into the §5.4 cascade. Measured on the rebalanced agent with the
	## pass-2 rule still in place — a 266-building city with a **ten**-vehicle
	## fleet reached **558 simultaneously open incidents** at game-hour 384.
	##
	## `STATION_PER_BUILDINGS` 45 is fitted to doc 06's own ladder rather than
	## chosen: `fire_station` L1 houses one engine and doc 06's
	## `structure_fire_global_scalar` 0.4 against a mean `fire_ignition_per_hour`
	## of ~2.5e-4 puts a 45-building block of the city at roughly one structure
	## fire per three game-days, which is one engine's duty cycle.
	const STATION_PER_BUILDINGS := 45
	const STATION_ORDER: Array[String] = ["fire_station", "police_station",
			"construction_yard"]

	func _civic_shortfall(api: Api) -> String:
		# a) the level ladder, unchanged from pass 2.
		if api.city_level() > _civic_at_level:
			var cheapest := _cheapest(api, INFRA)
			if cheapest != "":
				return cheapest
		# b) the station roster: one more engine house per STATION_PER_BUILDINGS.
		var want := 1 + api.sim.buildings.size() / STATION_PER_BUILDINGS
		var have := {}
		for id in api.sim.buildings:
			var b: Building = api.sim.buildings[id]
			if b.state == &"destroyed":
				continue
			var archetype := String(b.archetype)
			have[archetype] = int(have.get(archetype, 0)) + 1
		for archetype in STATION_ORDER:
			if int(have.get(archetype, 0)) < want:
				return archetype
		return ""

	## `LAND_BUDGET_SHARE` of the settled net, earmarked for the next block and
	## capped at that block's quoted all-in cost (price + doc 09 §2.3 development).
	func _credit_land(api: Api, hour: int) -> void:
		if not api.has_verb("cmd_buy_block"):
			return
		if hour - _land_quote_hour >= LAND_QUOTE_PERIOD or _land_block == "":
			_land_quote_hour = hour
			_land_block = api.purchasable_block()
			var quote := api.land_quote(_land_block)
			_land_target = float(int(quote.get("price", 0))) \
					+ float(int(quote.get("development_estimate", 0)))
		if _land_target <= 0.0:
			_land_fund = 0.0
			return
		var net := api.last_net()
		if net > 0.0:
			_land_fund += LAND_BUDGET_SHARE * net
		_land_fund = minf(_land_fund, _land_target)

	## Layer 2 — the growth ladder, exactly pass 2's order.
	func _grow(api: Api, hour: int) -> void:
		# 0. Expand outward when the land fund has covered the quote. Checked
		#    BEFORE the operating surplus, because the fund is the saved surplus.
		if _expand(api, hour):
			return
		var spare := api.balance() - reserve()
		if spare <= 0:
			return
		# 0a0. GENERATION, before the trunk: a pool that is short sheds whole
		#      circuits, and no amount of copper under it helps (Wave 24,
		#      doc 92 §63.3). See `GENERATION_RELIEF_RATIO` for the measurement.
		if maintains and _lead_generation(api, spare):
			return
		# 0a. The TRUNK, before the tap: a saturated feeder takes its whole
		#     subtree dark, and no number of transformers under it helps.
		if maintains and _relieve_feeders(api, hour, spare):
			return
		# 0a2. Then the hotspot: a transformer past 0.85 cooks, and doc 04 §2.9's
		#      parallel transformer is what takes the load off it.
		if maintains and _relieve_transformers(api, hour, spare):
			return
		# 0b. Keep the grid ahead of the building, not behind it (F-11).
		if maintains and _lead_grid(api, hour, spare):
			return
		# 1. Civic: one on every city level, plus a station roster sized to the
		#    city (see `_civic_shortfall`).
		var civic := _civic_shortfall(api)
		if civic != "" and spare >= api.build_cost(civic):
			if bool(api.place(civic)["ok"]):
				_civic_at_level = api.city_level()
				return
		# 2. Upgrade what is already standing, cheapest gate-clear row first.
		var upgrades := api.upgrade_candidates(REVENUE)
		if not upgrades.is_empty() \
				and float(spare) >= UPGRADE_HEADROOM * float(upgrades[0]["cost"]):
			api.upgrade(String(upgrades[0]["sim_id"]))
			return
		# 3. Then floorspace, on the 2:1 mix.
		var want_residential := _residential_streak < RESIDENTIAL_PER_COMMERCIAL
		var archetype := _pick(api, ["residential"] if want_residential else ["commercial"])
		if archetype == "":
			archetype = _pick(api, REVENUE)
		if archetype == "" or spare < api.build_cost(archetype):
			return
		if bool(api.place(archetype)["ok"]):
			if api.sim.catalog.category(archetype) == "residential":
				_residential_streak += 1
			else:
				_residential_streak = 0

	func _expand(api: Api, hour: int) -> bool:
		if not api.has_verb("cmd_buy_block") or _land_block == "":
			return false
		if _trunk_starved:
			return false  # not while the lights are going out on the land you own
		if hour - _expand_hour < EXPAND_COOLDOWN:
			return false
		if _land_target <= 0.0 or _land_fund + 0.5 < _land_target:
			return false
		if float(api.balance() - operating_reserve()) < _land_target:
			return false
		_expand_hour = hour
		if not bool(api.buy_block(_land_block)["ok"]):
			return false
		_land_fund = 0.0
		_land_block = ""
		_land_target = 0.0
		return true

	## Move to `tax_target` once and hold it. `cmd_set_tax_level` is a no-op that
	## returns ok when the rate is already there, so the cooldown guard is what
	## keeps the action log honest rather than what makes the command legal.
	func _hold_tax(api: Api, hour: int) -> bool:
		if tax_target < 0 or not api.has_verb("cmd_set_tax_level"):
			return false
		if api.tax_level() == tax_target:
			return false
		if hour - _tax_hour < 48:  # doc 03 §8 TAX_RATE_COOLDOWN_HOURS
			return false
		_tax_hour = hour
		return bool(api.set_tax_level(tax_target)["ok"])

	## Doc 04 §2.4: a CRITICAL/ESSENTIAL load survives a rolling shed its
	## STANDARD neighbours do not. Done once, over the founding civic roster —
	## a competent player sets this and forgets it.
	func _set_civic_priorities(api: Api) -> bool:
		if _priorities_set or not api.has_verb("cmd_set_priority"):
			return false
		_priorities_set = true
		var touched := false
		for id in Api._sorted(api.sim.buildings):
			var b: Building = api.sim.buildings[id]
			var category := api.sim.catalog.category(String(b.archetype))
			if category != "service" and category != "utility":
				continue
			touched = bool(api.set_priority(String(id), CIVIC_PRIORITY)["ok"]) or touched
		return touched

	## Grid ahead of growth — see `GRID_LEAD_TILES` for the F-11 measurement this
	## replaces. Two triggers, in the order that matters:
	##
	## 1. **A block with no grid at all.** Doc 09 §2.3 hands a developed block
	##    over with a utility corridor to its centre and no transformer, so all
	##    169 of its buildable tiles answer `E_UNSERVED` until the player buys the
	##    tap. `grid_shortfall_tile` finds it first because it scans blocks in
	##    sorted id order and that block has zero served tiles.
	## 2. **The served stock running down** anywhere else, before the wall.
	##
	## Still `E_NO_VERB`-safe and still budget-gated: this agent buys grid out of
	## the same surplus everything else comes out of, so a city that cannot pay
	## its payroll does not buy copper either.
	func _lead_grid(api: Api, hour: int, spare: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if hour - _grid_hour < GRID_COOLDOWN or spare < GRID_ATTEMPT_FLOOR:
			return false
		var tile := api.grid_shortfall_tile(GRID_LEAD_TILES)
		if tile.x < 0:
			return false
		_grid_hour = hour
		return bool(api.place_grid_component("transformer", tile, GRID_LEVEL)["ok"])

	## Generation ahead of the shed — see `GENERATION_RELIEF_RATIO` for the
	## doc 92 §63.3 measurement this answers. One number in, two purchases out,
	## in the order a competent player takes them:
	##
	## 1. **Upgrade the plant the city already has.** Doc 02 prices `L1 → L2` at
	##    $69,000 for doc 04 §2.2's 8,000 → 18,000 kW, against $60,000 for a
	##    whole second L1 plant at 8,000 — more capacity for less money, on
	##    ground the city already owns, needing no site and no trunk. The
	##    component keeps its old rating and stays OK for the whole job
	##    (`CitySim._commission_grid_node` re-rates it on COMPLETION), so the
	##    city is never darker for having started the upgrade.
	## 2. **Build one**, when every plant standing is at its top rung — or when
	##    the city somehow has none at all, which no founded city does.
	##
	## **There is no cooldown constant, and that is deliberate.** The fix is a
	## construction job with a duration doc 02 already publishes (20 game-hours
	## at L1→L2, 34 at L2→L3, 57 at L3→L4), and a shell in flight is
	## `under_construction`, which `archetype_upgrade_candidate` excludes and
	## `_generation_in_flight` catches for the build branch. The job IS the
	## cooldown, so this rule can neither queue two plants against one shortfall
	## nor need a swept number to stop it.
	func _lead_generation(api: Api, spare: int) -> bool:
		if not api.has_verb("cmd_place_building"):
			return false
		var caps := api.sim.grid.capacity_summary()
		if float(caps["load_ratio"]) < GENERATION_RELIEF_RATIO:
			return false
		if _generation_in_flight(api):
			return false
		var row := api.archetype_upgrade_candidate(GENERATION_ARCHETYPE)
		if not row.is_empty():
			if spare < int(row["cost"]):
				return false
			return bool(api.upgrade(String(row["sim_id"]))["ok"])
		if spare < api.build_cost(GENERATION_ARCHETYPE):
			return false
		return bool(api.place(GENERATION_ARCHETYPE)["ok"])

	## True while any generating shell is building or upgrading. `Building.state`
	## is `under_construction` for both jobs (doc 02 §2.2), and a plant that is
	## mid-job is the shortfall already being answered.
	func _generation_in_flight(api: Api) -> bool:
		for id: Variant in api.sim.buildings:
			var b: Building = api.sim.buildings[id]
			if String(b.archetype) != GENERATION_ARCHETYPE:
				continue
			if b.state == &"under_construction":
				return true
		return false

	## Trunk ahead of the relay — see `FEEDER_RELIEF_RATIO` for the doc 92 §17.3
	## measurement this answers. One number in, two possible purchases out:
	##
	## 1. **A feeder**, when some substation still has a slot (doc 04 §2.2 gives
	##    L1 two, L2 three). Routed to the middle of the hottest circuit, because
	##    §2.9's transfer rule only picks up transformers the new route passes
	##    near — copper drawn into empty ground would relieve nothing that exists.
	## 2. **A substation**, when none does. The city cannot buy copper at any
	##    price with every slot full, and doc 09 §2.9.5 fills both of SUB-A's on
	##    game-hour zero, so a growing city buys its SECOND substation the way it
	##    buys its second fire station.
	##
	## Budget-gated like everything else this agent does, `E_NO_VERB`-safe, and
	## gated on `maintains` so `disaster_neglect` still differs in one field.
	func _relieve_feeders(api: Api, hour: int, spare: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if api.feeder_peak_ratio() < FEEDER_RELIEF_RATIO:
			_trunk_starved = false
			return false
		if hour - _feeder_hour < FEEDER_COOLDOWN:
			return false
		var target := api.hot_feeder_target()
		if target.x < 0:
			return false
		if api.has_feeder_slot():
			_trunk_starved = false
			if spare < FEEDER_ATTEMPT_FLOOR:
				return false
			_feeder_hour = hour
			return bool(api.route_feeder(target, FEEDER_CLASS)["ok"])
		# Every slot is full, so the ONLY thing that makes more copper buyable at
		# any price is a substation. Two things follow, and both are what a
		# competent player does rather than what a tidy one does:
		#
		#   * it is gated on its own price and nothing else — putting the routing
		#     floor on top of it (measured) left the agent unable to afford it
		#     for the whole back half of a 50-game-day run while it spent the
		#     same money on taps;
		#   * `_trunk_starved` stands the LAND FUND down until it is bought — you
		#     do not buy the next block while the lights are going out on the one
		#     you have. **This one is a judgement, not a measurement**, and it is
		#     labelled as such: it was added while chasing seed 4242's late game,
		#     and the change that actually fixed that seed was the source
		#     resolution in `CitySim._feeder_source` — 16 × `E_NO_SLOT`, ONE
		#     substation and 18.0 % dark at 50 game-days, against 0 × `E_NO_SLOT`,
		#     three substations and 5.9 % on the shipped code. It is kept because
		#     an agent that saves for its next block while its trunk sits at
		#     r = 1.5 is not a competent player, and because it costs nothing
		#     while the trunk is healthy: the flag is false on every hour the
		#     peak is under WARNING.
		_trunk_starved = true
		if spare < api.build_cost("substation"):
			return false
		_feeder_hour = hour
		var bought := bool(api.build_substation(target)["ok"])
		if bought:
			_trunk_starved = false
		return bought

	## Doc 04 §2.9's parallel transformer, bought — see `HOTSPOT_RADIUS` for the
	## measurement. Budget-gated on the same floor a lead tap uses, because it is
	## the same purchase at the same price; what differs is the trigger.
	func _relieve_transformers(api: Api, hour: int, spare: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if hour - _hotspot_hour < HOTSPOT_COOLDOWN or spare < GRID_ATTEMPT_FLOOR:
			return false
		if api.transformer_peak_ratio() < HOTSPOT_RATIO:
			return false
		var tile := api.relief_spot(GRID_LEVEL, HOTSPOT_RADIUS)
		if tile.x < 0:
			return false
		_hotspot_hour = hour
		return bool(api.place_grid_component("transformer", tile, GRID_LEVEL)["ok"])

	## The densest affordable row inside `categories` — same ranking as greedy,
	## but only ever spent out of the surplus above the reserve.
	func _pick(api: Api, categories: Array) -> String:
		var best := ""
		var best_score := -1.0
		var spare := api.balance() - reserve()
		for archetype in api.buildable(categories):
			var cost := api.build_cost(archetype)
			if cost <= 0 or spare < cost:
				continue
			var stats: Dictionary = api.sim.catalog.stats(archetype, 1)
			var score := float(int(stats.get("population", 0)) + int(stats.get("jobs", 0))) \
					/ float(cost)
			if score > best_score + 1e-12:
				best_score = score
				best = archetype
		return best

	func _cheapest(api: Api, categories: Array) -> String:
		var best := ""
		var best_cost := 0
		for archetype in api.buildable(categories):
			var cost := api.build_cost(archetype)
			if cost <= 0:
				continue
			if best == "" or cost < best_cost:
				best = archetype
				best_cost = cost
		return best


## `balanced` with the tax slider pinned to its top detent (doc 03 §8
## `TAX_RATE_MAX` 0.16 = level 12) from game-hour 0, and nothing else changed.
## Doc 03 §2.2 says that detent buys `tax_policy_factor` 0.16/0.09 = **1.778×**
## on every revenue line and charges `happiness_tax_delta −15.4` plus
## `growth_rate_multiplier 0.755`. Whether that is a tradeoff or a free lunch is
## the single question this agent exists to answer: it is measured against
## `balanced`, which is the same builder at the founding rate.
class TaxSqueezer extends Balanced:

	func _init() -> void:
		tax_target = 1_000_000  # clamped to the top detent in `act`

	func id() -> String:
		return "tax_squeezer"

	func describe() -> String:
		return "balanced, but the tax slider is pinned to TAX_RATE_MAX from hour 0"

	func act(api: Api, hour: int) -> void:
		# The ladder length is data (doc 03 §8), so the top detent is read, never
		# written: a TAX_RATE_MAX edit moves this agent without a code change.
		tax_target = api.sim.tax_level_count() - 1
		super(api, hour)


## `balanced` with maintenance switched off, and nothing else changed: never
## repairs a building, never sets a priority class, never buys a transformer to
## answer a wall. Everything it builds, it builds exactly as `balanced` does.
##
## This is the constitution's thesis under test — *"You built it. Now keep it
## alive."* If neglect is not measurably worse than maintenance over three
## game-weeks, then the pressure systems (doc 06 incidents, doc 07 weather) are
## not biting and the second half of the sentence is decoration.
class DisasterNeglect extends Balanced:

	func _init() -> void:
		maintains = false

	func id() -> String:
		return "disaster_neglect"

	func describe() -> String:
		return "balanced, but never repairs, never prioritises, never buys grid"


## **The student** — the agent doc 09 §2.14's curriculum is PACED against, and
## the only one in this file that reads the goals sheet.
##
## Every other strategy here plays the city. This one plays the SHEET: once a
## game-hour it looks at the active level's first unmet objective and spends its
## one action on that, and only when the objective wants nothing a verb can give
## does it fall through to `balanced`'s own ladder. It is therefore `balanced`
## **plus a reading habit** — the same builder, the same reserve, the same
## maintenance purse, following the instructions the game now prints.
##
## Two things it is deliberately NOT:
##
##   * it is not optimal — it takes the objective's action even when a better one
##     exists, because that is what a player following a checklist does;
##   * it is not a second measurement of the ladder — `balanced` remains the
##     agent doc 92 §19's population rungs are fitted on, and this agent's job is
##     to answer the different question doc 92 §22 asks: *how long does the
##     taught route take?*
class Curriculum extends Balanced:

	## Objectives no verb can advance. Population and happiness are consequences,
	## an endurance streak is time, a resolved incident is doc 06's to create, and
	## a block finishes developing on doc 09's six-phase clock. The agent plays on
	## and they arrive — which is exactly what the player does.
	const PASSIVE_KINDS: Array[String] = [
		"reach_population", "reach_happiness", "reach_stability", "reach_treasury",
		"survive_no_abandonment", "resolve_incidents", "develop_block",
	]

	func id() -> String:
		return "curriculum"

	func describe() -> String:
		return "balanced, plus the goals sheet: one action a game-hour on the " \
				+ "active level's next objective"

	## The price of the objective the agent is currently SAVING for, or 0. Added
	## to [reserve] so the growth ladder cannot spend it.
	##
	## **This field is the whole agent.** Without it the student starves: a shop
	## costs $2,600, a house costs $1,200, and `_grow` spends every surplus down
	## to the reserve every game-hour — so the surplus never reaches $2,600 and
	## the objective that asks for two shops is outbid by cheaper housing forever.
	## Measured before this earmark existed, seed 1337: `l2_stores` completed at
	## game-hour **206**, against game-hour 24 with it. A player saving for the
	## thing the game just asked them to build stops buying the other thing, and
	## `Balanced` already has the machinery for exactly that — the land fund.
	var _goal_price: int = 0

	## **The REST of the open checklist** (Wave 22, doc 92 §61.4). `_goal_price`
	## is the one thing the hour is saving for; this is everything else the
	## active level still asks for, and the growth ladder may not spend it
	## either.
	##
	## It is the same argument `_goal_price` was written on, one level of the
	## curriculum later. With one earmark and twelve rows, level 7 measured like
	## this: the agent ticked the cheap rows, spent every remaining surplus on
	## apartments, and by game-day 70 was running **11,496 residents in 476
	## apartments** whose water demand had swallowed the whole zone's supply —
	## so every one of the twelve upgrades was refused `E_WATER_HEADROOM` and the
	## $207,000 data-centre step was refused `E_FUNDS` on a $191,301 treasury.
	## That is not a player following a checklist; a player saving for twelve
	## things does not build four hundred and seventy-six apartments first.
	var _checklist_price: int = 0

	## One game-day between capacity purchases — see [_relieve] for the
	## measurement that set it.
	const RELIEF_COOLDOWN_H := 24
	## The game-hour the last capacity purchase landed on. `-RELIEF_COOLDOWN_H`
	## so the first one is free.
	var _relief_hour: int = -RELIEF_COOLDOWN_H

	func reserve() -> int:
		return super() + _goal_price + _checklist_price

	## **The whole checklist, not just its first line** (Wave 22, doc 92 §61.3).
	##
	## This used to read exactly one objective — the active level's first unmet
	## row — and it worked because no level had more than three buyable rows and
	## they were authored in the order a player would do them. Doc 09 §2.14.2's
	## level 7 has TWELVE, and the first of them is a house upgrade that can be
	## blocked by power, by condition or by every house in the city already
	## standing at its top rung. A one-row reader stalls on it and the other
	## eleven never get looked at, which would have made the capstone level
	## measure as unreachable and would have said nothing true about the game.
	##
	## So the hour is spent in two passes, and both are what a player with a
	## checklist does: **save for the first thing you cannot afford, and while
	## you are saving, tick off anything on the list you can.** The earmark is
	## still exactly one price — the hour buys one thing — and `reserve()` still
	## protects it from the growth ladder.
	##
	## It changes the arc BELOW level 7 as well (levels 3, 4, 5 and 6 each carry
	## two or three buyable rows) and doc 92 §61.3 measures that separately from
	## the grants, on the old table, so the two are not attributed to each other.
	func act(api: Api, hour: int) -> void:
		# Before `super.reserve()` below, which reads the floor this resolves.
		note_founding_purse(api)
		_goal_price = 0
		_checklist_price = 0
		var wanted := _unmet_objectives(api)
		# Priced ONCE per hour, into a parallel array. `_price_of` runs command
		# previews and, for the level-7 kinds, walks the roster — pricing the
		# same twelve rows three times an hour is the difference between a
		# 45-game-day run that finishes and one that does not.
		var prices: Array[int] = []
		for raw: Variant in wanted:
			prices.append(_price_of(api, raw as Dictionary))
		var saving_index := -1
		for i in wanted.size():
			if prices[i] > 0 and api.balance() - prices[i] < super.reserve():
				_goal_price = prices[i]   # save for it; the growth ladder may not
				saving_index = i
				break
		# Everything else the level still asks for, held back from `_grow`.
		for i in wanted.size():
			if i != saving_index:
				_checklist_price += prices[i]
		for i in wanted.size():
			if i == saving_index:
				continue   # already priced and already unaffordable
			# The floor this row has to clear is the reserve MINUS its own share
			# of the checklist: a row may spend the money that was being held for
			# it, and may not spend the money being held for its neighbours.
			if prices[i] > 0 and api.balance() - prices[i] < reserve() - prices[i]:
				continue
			if _serve(api, wanted[i]):
				# The hour's ACTION is spent, but the two per-hour accruals are
				# bookkeeping rather than actions — skipping them would make a
				# studious agent quietly worse at maintenance than a lazy one.
				if maintains:
					_credit_maintenance(api)
				_credit_land(api, hour)
				return
		super(api, hour)

	## The active level's unmet objectives that a verb can advance, in authored
	## order — which is teaching order, and therefore the order a player works
	## them.
	func _unmet_objectives(api: Api) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var view: Dictionary = api.sim.goals.view()
		if bool(view.get("complete", true)):
			return out
		for raw: Variant in (view["objectives"] as Array):
			var obj: Dictionary = raw
			if not bool(obj["done"]) and not PASSIVE_KINDS.has(str(obj["kind"])):
				out.append(obj)
		return out

	## What serving `obj` costs, or 0 when the answer is "nothing" or "unknown".
	func _price_of(api: Api, obj: Dictionary) -> int:
		match str(obj["kind"]):
			"build_archetype":
				return api.build_cost(str(obj["archetype"]))
			"place_grid_component":
				var tile := api.best_transformer_tile()
				if tile.x < 0:
					return 0
				return int((api.grid_quote(str(obj["kind_id"]), tile, GRID_LEVEL)
						.get("payload", {}) as Dictionary).get("cost", 0))
			"upgrade_building":
				var rows := api.upgrade_candidates()
				return 0 if rows.is_empty() else int(rows[0]["cost"])
			"upgrade_to_level":
				# The price of the NEXT step toward the top, not of the whole climb:
				# the objective is served one rung at a time and the earmark only has
				# to protect the rung the agent is buying this game-hour.
				var top := api.top_upgrade_candidate()
				return 0 if top.is_empty() else int(top["cost"])
			"upgrade_archetype":
				# THREE prices, matching `_serve`'s three answers (doc 09
				# §2.14.2's level 7): the upgrade itself, the first one of a type
				# the city does not own, or the CAPACITY a headroom refusal is
				# asking for. The earmark protects whichever of the three the
				# hour is about to spend and never more than one, because the
				# hour buys one thing.
				var archetype := str(obj["archetype"])
				var row := api.archetype_upgrade_candidate(archetype)
				if not row.is_empty():
					return int(row["cost"])
				if api.archetype_count(archetype) == 0:
					return api.build_cost(archetype)
				var blocked := api.blocked_upgrade(archetype)
				# `E_FUNDS` is the one blocker whose answer is *money*, and
				# therefore the only one this earmark can price.
				# `archetype_upgrade_candidate` cannot report it — it filters on
				# a preview that `E_FUNDS` fails — so without this arm the most
				# expensive row in the game (the $207,000 data-centre step) was
				# the one row the agent never saved for.
				#
				# **A HEADROOM blocker is priced at ZERO on purpose.** Its fix is
				# a transformer or a pump, and one of those unblocks ALL the rows
				# it is short for; pricing it per row would earmark twelve copies
				# of one purchase and starve the checklist it was protecting.
				# `_serve` buys it, once, on its own cooldown.
				if blocked.is_empty() or String(blocked["blocker"]) != "E_FUNDS":
					return 0
				return int(blocked["cost"])
			"buy_block":
				var block := api.purchasable_block()
				if block == "":
					return 0
				var quote := api.land_quote(block)
				return int((quote.get("payload", {}) as Dictionary).get("price", 0))
			"place_water_component":
				return api.water_quote(str(obj["kind_id"]), 1)
			"stamp_road_tiles":
				# The WHOLE run, because doc 10 lays it as one command and one
				# bill: an agent that earmarked one tile's price would start a
				# run it could not finish paying for.
				return api.road_quote(_road_tiles_wanted(api, obj))
			"repair_buildings":
				var worst := api.maintenance_queue(1.0)
				return 0 if worst.is_empty() else api.repair_quote(String(worst[0]["sim_id"]))
		return 0

	func _serve(api: Api, obj: Dictionary) -> bool:
		match str(obj["kind"]):
			"build_archetype":
				var archetype := str(obj["archetype"])
				if api.min_city_level(archetype) > api.city_level():
					return false
				return bool(api.place(archetype)["ok"])
			"place_grid_component":
				var tile := api.best_transformer_tile()
				if tile.x < 0:
					return false
				return bool(api.place_grid_component(
						str(obj["kind_id"]), tile, GRID_LEVEL)["ok"])
			"upgrade_building":
				var rows := api.upgrade_candidates()
				if rows.is_empty():
					return false
				return bool(api.upgrade(String(rows[0]["sim_id"]))["ok"])
			"upgrade_to_level":
				var top := api.top_upgrade_candidate()
				if not top.is_empty():
					return bool(api.upgrade(String(top["sim_id"]))["ok"])
				# Nothing cleared the gate. Doc 92 §24.8: on the sixth rung the
				# reason is POWER — the step is worth 124 kW on a house and 1,145
				# on an apartment — and the answer to a power refusal is copper at
				# the building that was refused, which is exactly what the panel
				# tells the player. $2,800 for a level-3 transformer against a
				# $73,572 upgrade: the agent is not being clever, it is reading.
				var blocked := api.power_blocked_top_rung()
				if blocked.is_empty():
					return false
				var level := int(blocked["transformer_level"])
				var tile := api.relief_spot_near(blocked["tile"], level, HOTSPOT_RADIUS)
				if tile.x < 0:
					return false
				return bool(api.place_grid_component("transformer", tile, level)["ok"])
			"upgrade_archetype":
				# THREE answers, in the order a player would try them, and the
				# third one is the level's actual lesson.
				var archetype := str(obj["archetype"])
				var row := api.archetype_upgrade_candidate(archetype)
				if not row.is_empty():
					return bool(api.upgrade(String(row["sim_id"]))["ok"])
				if api.archetype_count(archetype) == 0:
					# Buy the first one. `data_center` is what this branch exists
					# for — no earlier level ever mentions it, so at level 7 the
					# city has never owned one.
					if api.min_city_level(archetype) > api.city_level():
						return false
					return bool(api.place(archetype)["ok"])
				# It exists and the gate refused it. Doc 92 §61.4: on the arc
				# the grants produce, the refusal is not money — it is
				# `E_POWER_HEADROOM` or `E_WATER_HEADROOM` on a city that grew
				# faster than its own utilities. The answer to a headroom
				# refusal is CAPACITY, bought where the refusal happened, and it
				# is exactly what the building panel tells the player to do.
				return _relieve(api, api.blocked_upgrade(archetype))
			"set_tax_rate":
				# One detent up, which is the smallest real move the slider
				# makes. The objective teaches that the slider EXISTS and that
				# it has a price; pinning it to the top is `tax_squeezer`'s job.
				var next := mini(api.tax_level() + 1, api.sim.tax_level_count() - 1)
				if next == api.tax_level():
					return false
				return bool(api.set_tax_level(next).get("ok", false))
			"buy_block":
				var block := api.purchasable_block()
				if block == "":
					return false
				return bool(api.buy_block(block).get("ok", false))
			"place_water_component":
				return bool(api.place_water_component(str(obj["kind_id"]), 1).get("ok", false))
			"stamp_road_tiles":
				# One run, the length the objective still needs. Doc 10 bills the
				# FRESH tiles, so a run that overlaps nothing is billed in full —
				# which is the decision the objective is teaching.
				return bool(api.place_road(_road_tiles_wanted(api, obj)).get("ok", false))
			"repair_buildings":
				var worst := api.maintenance_queue(1.0)
				if worst.is_empty():
					return false
				return bool(api.repair(String(worst[0]["sim_id"])).get("ok", false))
		return false

	## Buy the capacity a blocked upgrade is short of (Wave 22, doc 92 §61.4).
	## `blocked` is [Api.blocked_upgrade]'s row, or `{}` for "nothing is blocked",
	## in which case this spends nothing and returns false so the hour falls
	## through to the growth ladder.
	##
	## Two blockers are answerable and the rest are not, deliberately:
	## `E_POWER_HEADROOM` buys a parallel transformer at the building that was
	## refused (the same move `upgrade_to_level` already makes for the tower
	## tier), and `E_WATER_HEADROOM` buys a pump. `E_CONDITION` is answered by
	## the maintenance purse `Balanced` already runs, `E_STATE` by waiting for
	## the crew, and `E_AVENUE` by doc 10's road tool — all three are somebody
	## else's hour, and an agent that tried to answer them here would be doing
	## the level's work twice.
	##
	## **[RELIEF_COOLDOWN_H] is what makes this an agent and not a leak.** A
	## bought pump is not a *supplying* pump until its crew is done, so the
	## refusal it was bought for is still standing the next game-hour — and the
	## first version of this method answered that by buying another one, every
	## hour, for as long as the row stayed open. Measured (doc 92 §61.4): seed
	## 9001 bought **64 pumps for $2,946,924** and still did not finish the level.
	## One game-day is the wait a player takes before deciding the last thing they
	## bought did not work, and it is longer than any single water or grid
	## component takes to build.
	func _relieve(api: Api, blocked: Dictionary) -> bool:
		if blocked.is_empty():
			return false
		if api.hour - _relief_hour < RELIEF_COOLDOWN_H:
			return false
		# **The clock starts on the PURCHASE, not on the attempt**, and the
		# difference is measured: charging the cooldown for a failed attempt took
		# the arc from two seeds finishing level 7 to none, because a city whose
		# map is momentarily full gets one try a game-day and spends the level
		# waiting. A failed relief buys nothing, so there is nothing to wait for.
		var bought := false
		# Both arms try the SAME two doors in the same order — build beside it,
		# and if the map has no room left, build it taller. A full map is not a
		# hypothetical here: seed 9001 reaches level 7 with 328 apartments and
		# 164 offices standing (doc 92 §61.4).
		match String(blocked["blocker"]):
			"E_POWER_HEADROOM":
				var level := int(blocked["transformer_level"])
				var tile := api.relief_spot_near(blocked["tile"], level, HOTSPOT_RADIUS)
				bought = tile.x >= 0 and bool(api.place_grid_component(
						"transformer", tile, level)["ok"])
				if not bought:
					bought = bool(api.upgrade_grid_component(
							String(blocked.get("power_at", "")))["ok"])
			"E_WATER_HEADROOM":
				bought = bool(api.place_water_component("pump", 1).get("ok", false))
				if not bought:
					bought = bool(api.upgrade_water_node()["ok"])
		if bought:
			_relief_hour = api.hour
		return bought

	## How much of a road objective is left to lay, floored at one tile. The
	## agent lays the REMAINDER in one run rather than the whole target, so a
	## partially-met objective is finished rather than restarted.
	static func _road_tiles_wanted(_api: Api, obj: Dictionary) -> int:
		return maxi(1, int(ceil(float(obj["target"]) - float(obj["current"]))))


## **The tapping agent** — `curriculum` plus doc 06 §2.16's tap, and the first
## fine-path strategy in this file (RR-86, doc 92 §35.4 item 1).
##
## Doc 92 §35 had to rule on the opportunity layer's income share with no agent
## that could collect one, so §35.2's ceiling was computed from SPAWN TELEMETRY
## on a founding city that never changed: no city level, no second station, no
## growing kerb pool, and no income to compare against but the founding hour's.
## Every one of those moves on a real arc, and three of them move the bounty.
## This agent is the instrument that closes it.
##
## ── what it is ────────────────────────────────────────────────────────────
##
## `curriculum` — the taught route, the agent gate 21 and doc 92 §36.4 are
## measured on — **with one addition and nothing else changed**: once a
## game-minute it taps the nearest live offer. It is the controlled pair doc 92
## uses everywhere else, and its partner is `curriculum` itself on the same
## seeds: any difference between the two rows is the street layer and nothing
## else, because the builder underneath is the same object with the same reserve,
## the same maintenance purse and the same checklist.
##
## ── what it is NOT, said plainly, because the number depends on it ────────
##
## **It is a CEILING agent.** It has no camera, no travel time and no attention
## budget: `SWEEP_RADIUS_M` covers the whole 112-tile world, so every offer it is
## awake for is an offer it takes. A human collects a fraction of that — doc 92
## §35.3 costed the ceiling at twenty-four real minutes of uninterrupted
## map-scrubbing per game-day. So `street_income` from this agent is the MOST the
## layer can pay a player who is playing the curriculum, which is exactly the
## bound doc 03 §2.5's `STREET_CEILING_SHARE_MAX` is written against, and it is
## not a forecast of a session.
##
## **One tap per game-minute is a real bound and it is not the binding one.**
## The spawner delivers about 0.57 offers per game-hour — roughly one tap in a
## hundred minutes — so the agent is idle almost always and the cap never bites.
## It is written as a cap anyway, because an agent that emptied the roster in one
## call would be driving a verb the player does not have.
class Collector extends Curriculum:
	## Ground metres. The world is 112 tiles at 8 m (constitution §6), so its
	## diagonal is ~1,267 m: this is deliberately unbounded, and the docstring
	## above is where that choice is argued rather than hidden in a constant.
	const SWEEP_RADIUS_M := 2000.0
	## Tile the sweep measures "nearest" from — the centre of the world, so the
	## tie-break between two simultaneous offers is a fixed, seed-independent
	## geometry and not an accident of iteration order.
	const SWEEP_CENTRE := Vector2i(TileGrid.SIZE / 2, TileGrid.SIZE / 2)

	func id() -> String:
		return "collector"

	func describe() -> String:
		return ("the curriculum agent plus doc 06 §2.16's tap: one street "
				+ "opportunity per game-minute, unbounded radius — the CEILING "
				+ "of the street layer on a played arc, not a session forecast")

	func wants_game_minutes() -> bool:
		return true

	func tick_minute(api: Api, _minute: int) -> void:
		# The cheap guard first. On ~99 game-minutes in a hundred the roster is
		# empty, and `live_count()` is an array size against
		# `opportunity_near()`'s distance sweep plus a command round-trip.
		if api.live_opportunities() <= 0:
			return
		api.collect_nearby(SWEEP_CENTRE, SWEEP_RADIUS_M)


## `balanced` that also PREPARES. Doc 07 §2.7.7's six actions are optional by
## design — *"a city that does nothing is still playable, just worse"* — so the
## only way to measure what preparation is worth is to run an agent that takes it
## against one that does not. This is that agent, and `balanced` is its control:
## it differs on exactly the game-hours a `severe_thunderstorm` is pending.
##
## It takes the CHEAPEST available actions first and stops at
## `storm.reward.min_prep_actions`, which is the Storm Ready threshold. That is
## the rational play and it is also the one that makes the measurement legible:
## an agent that bought all six would confound "preparation works" with "spending
## works".
class StormReady extends Balanced:

	func id() -> String:
		return "storm_ready"

	func describe() -> String:
		return "balanced, plus doc 07 §2.7.7's prep window when a storm is coming"

	func act(api: Api, hour: int) -> void:
		_prepare(api)
		super(api, hour)

	func _prepare(api: Api) -> void:
		var overview: Dictionary = api.sim.storm_prep_overview()
		if not bool(overview["open"]):
			return
		var target := int(overview["min_prep_actions"])
		if (overview["taken"] as Array).size() >= target:
			return
		var affordable: Array = []
		for entry in (overview["actions"] as Array):
			var row: Dictionary = entry
			if not bool(row["available"]) or bool(row["taken"]):
				continue
			if bool(row["needs_target"]):
				continue  # a sandbag needs a block; this agent has no map opinion
			if int(row["cost"]) > api.balance():
				continue
			affordable.append(row)
		affordable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["cost"]) != int(b["cost"]):
				return int(a["cost"]) < int(b["cost"])
			return String(a["id"]) < String(b["id"]))
		for row in affordable:
			if (api.sim.director.prep_actions as Array).size() >= target:
				return
			api.storm_prep(String((row as Dictionary)["id"]))


class Factory extends RefCounted:

	static func make(strategy_id: String) -> Strategy:
		match strategy_id:
			"curriculum":
				return Curriculum.new()
			"collector":
				return Collector.new()
			"do_nothing":
				return DoNothing.new()
			"greedy_growth":
				return GreedyGrowth.new()
			"infrastructure_first":
				return InfrastructureFirst.new()
			"balanced":
				return Balanced.new()
			"tax_squeezer":
				return TaxSqueezer.new()
			"disaster_neglect":
				return DisasterNeglect.new()
			"storm_ready":
				return StormReady.new()
		return null


# ===========================================================================
# The run loop
# ===========================================================================

class Runner extends RefCounted:

	## One run: boot, drive, sample, summarise. Returns the JSON document.
	static func run_one(strategy_id: String, seed_value: int, opts: Options) -> Dictionary:
		var sim := CitySim.boot_from_files(seed_value, opts.difficulty)
		var strategy := Factory.make(strategy_id)
		var api := Api.new(sim)
		var total_hours := opts.hours()
		var samples: Array[Dictionary] = []
		var events: Dictionary = {}
		var coarse := opts.mode == "coarse"

		# Founding sample (hour 0) so every curve starts from a stated t0.
		sim.bus.drain()
		samples.append(_sample(sim, 0, {}, 0.0))

		# Doc 06 §2.16's tap needs the game-minute, and only on the fine path
		# (RR-86). `Strategy.wants_game_minutes` explains why this is opt-in.
		var sliced := not coarse and strategy.wants_game_minutes()
		for h in total_hours:
			api.hour = h
			strategy.act(api, h)
			if coarse:
				# Coarse STEP, not a catch-up SESSION: is_catchup=true would put
				# every run under doc 08's offline fairness rules and silence the
				# Disaster Director structurally (the pass-2 blind spot).
				sim.advance_coarse_hours(1, false)
			elif sliced:
				advance_hour_by_minutes(sim, strategy, api, h)
			else:
				sim.advance_hours(1.0)
			var settled := _drain(sim, events)
			var blackout := _blackout_minutes(sim)
			var sample := _sample(sim, h + 1, settled, blackout)
			samples.append(sample)
			if strategy is Balanced:
				(strategy as Balanced).note_expense(float(sample["expenses"]))

		var summary := _summarise(sim, api, samples, opts)
		var doc := {
			"schema_version": SCHEMA_VERSION,
			"harness": {
				"tool": "tools/playtest.gd",
				"mode": opts.mode,
				"days": opts.days,
				"hours": total_hours,
				"sample_period_hours": 1,
			},
			"run": {
				"strategy": strategy_id,
				"strategy_note": strategy.describe(),
				"seed": seed_value,
				"difficulty": sim.difficulty_preset(),
				"boot_errors": _boot_errors(sim),
			},
			"verbs": _verb_map(api),
			"samples": samples,
			"actions": api.actions,
			"events": _sorted_counts(events),
			"summary": summary,
			"state_hash": sim.state_hash(),
		}
		doc["digest"] = _digest(samples)
		return doc

	## ONE game-hour on the fine path, cut into sixty game-minutes with the
	## strategy given the seam between them (RR-86).
	##
	## **This must be bit-identical to `sim.advance_hours(1.0)` for a strategy
	## that does nothing in the seam**, and it is by construction rather than by
	## luck: `advance_hours(x)` is `advance_fine_n(roundi(x × 240))`, `1.0/60.0`
	## rounds to exactly 4 ticks, and `TickScheduler` carries no per-call state —
	## so sixty calls of four ticks are the same 240 ticks in the same order.
	## `tests/test_playtest_harness.gd` asserts it on `state_hash()`, on both a
	## slicing and a non-slicing agent, because a slice that drifted would make
	## every collector measurement a measurement of a different city.
	##
	## Shared with `BalanceGateRig`, which needs the identical loop: a gate and a
	## report row have to be the same measurement (the rig's own header).
	static func advance_hour_by_minutes(sim: CitySim, strategy: Strategy, api: Api,
			hour: int) -> void:
		for m in MINUTES_PER_HOUR:
			sim.advance_hours(1.0 / float(MINUTES_PER_HOUR))
			strategy.tick_minute(api, hour * MINUTES_PER_HOUR + m)

	# --- sampling -----------------------------------------------------------

	## One game-hour of city state. Every field is read off the live sim.
	static func _sample(sim: CitySim, hour: int, settled: Dictionary,
			blackout_minutes: float) -> Dictionary:
		# `start_upgrade()` reuses `under_construction`, so this counts both
		# fresh sites and in-flight upgrades — every crane in the city.
		var under_construction := 0
		var dark := 0
		var metered := 0
		var damaged := 0
		var destroyed := 0
		var min_condition := 1.0
		var condition_sum := 0.0
		var counted := 0
		for id in sim.buildings:
			var b: Building = sim.buildings[id]
			if b.state == &"under_construction":
				under_construction += 1
			if b.state == &"damaged":
				damaged += 1
			if b.state == &"destroyed":
				destroyed += 1
			else:
				min_condition = minf(min_condition, b.condition)
				condition_sum += b.condition
				counted += 1
			if b.archetype == &"substation":
				continue
			metered += 1
			if not sim.grid.is_powered(String(id)):
				dark += 1
		return {
			"h": hour,
			"day": hour / HOURS_PER_DAY,
			"hour_of_day": sim.clock.hour_of_day(),
			"treasury": sim.treasury.balance,
			"net": float(settled.get("net", 0.0)),
			"revenue": float(settled.get("gross", 0.0)),
			"expenses": float(settled.get("expense", 0.0)),
			## Doc 03 §2.5's `city_services` line for the hour just settled —
			## dispatch payouts plus street collections (report 98 RR-78). The
			## money pass measures its share of net, so it needs a column.
			"city_services": float(settled.get("city_services", 0.0)),
			"assistance": float(settled.get("assistance", 0.0)),
			"population": sim.population.city_population,
			"happiness": sim.happiness.happiness,
			"stability": sim.districts.city_stability,
			"city_level": sim.progression.city_level,
			## Doc 09 §2.14. Separate from `city_level` on purpose: the two
			## differ exactly when the population ladder is carrying a city the
			## curriculum has not, which is the shape of doc 93 §G1's ruling and
			## the thing a pacing report has to be able to see.
			"goal_level": sim.goals.earned_level if sim.goals != null else 0,
			"blackout_minutes": blackout_minutes,
			"buildings": sim.buildings.size(),
			"metered_buildings": metered,
			"dark_buildings": dark,
			"under_construction": under_construction,
			"deferred_liability": sim.treasury.deferred_liability,
			# --- pass 2: the neglect / policy / expansion channels ------------
			"damaged_buildings": damaged,
			"destroyed_buildings": destroyed,
			"min_condition": min_condition,
			"mean_condition": condition_sum / maxf(1.0, float(counted)),
			"open_incidents": sim.incidents.active_count() if sim.incidents != null else 0,
			"failed_components": _failed_components(sim),
			"tax_rate": sim.tax_rate,
			"blocks_owned": sim.world.owned_count(),
		}


	## Grid components the doc 04 §2.6 thermal model has taken out permanently.
	## `PowerGrid.repair_component()` is doc 06's to call; this is the count that
	## says whether anything ever calls it.
	static func _failed_components(sim: CitySim) -> int:
		var failed := 0
		for id in sim.grid.component_ids():
			if String((sim.grid.component(String(id)) as Dictionary).get("state", "")) == "FAILED":
				failed += 1
		return failed

	## Building-minutes of lost supply in the hour just settled:
	## `Σ_b (1 − availability_b) × 60`. 0 in a fully lit city; 60 for one
	## building dark for the whole hour. Substations draw no service load
	## (doc 04 §2.3) and are excluded.
	static func _blackout_minutes(sim: CitySim) -> float:
		var total := 0.0
		for id in sim.buildings:
			var b: Building = sim.buildings[id]
			if b.archetype == &"substation":
				continue
			total += (1.0 - sim.grid.power_availability_hour(String(id))) * 60.0
		return total

	## Drains the event bus, tallies types, and returns the hour's economy
	## settlement (doc 03's `economy_hour_settled`).
	static func _drain(sim: CitySim, events: Dictionary) -> Dictionary:
		var settled := {}
		for event in sim.bus.drain():
			var type := String(event["type"])
			events[type] = int(events.get(type, 0)) + 1
			if type == "economy_hour_settled":
				settled = event
			elif type == "BuildingPowerChanged":
				var key := "BuildingPowerChanged:" + String(event.get("state", ""))
				events[key] = int(events.get(key, 0)) + 1
			elif type == "incident_created":
				# Doc 92 §18 wants the MIX, not just the count: the ambient floor
				# is authored one channel at a time, so the only way to check the
				# authored split against the delivered one is to bucket by type.
				var key := "incident_created:" + String(event.get("incident_type", ""))
				events[key] = int(events.get(key, 0)) + 1
		return settled

	# --- summary ------------------------------------------------------------

	static func _summarise(sim: CitySim, api: Api, samples: Array[Dictionary],
			opts: Options) -> Dictionary:
		var first: Dictionary = samples[0]
		var last: Dictionary = samples[samples.size() - 1]
		var treasury_min: int = int(first["treasury"])
		var treasury_max: int = int(first["treasury"])
		var happiness_min: float = float(first["happiness"])
		var stability_min: float = float(first["stability"])
		var population_peak: int = int(first["population"])
		var net_sum := 0.0
		var blackout_total := 0.0
		var metered_minutes := 0.0
		var settled_hours := 0
		var condition_min := float(first["min_condition"])
		var incident_hours := 0.0
		for i in range(1, samples.size()):
			var s: Dictionary = samples[i]
			treasury_min = mini(treasury_min, int(s["treasury"]))
			treasury_max = maxi(treasury_max, int(s["treasury"]))
			happiness_min = minf(happiness_min, float(s["happiness"]))
			stability_min = minf(stability_min, float(s["stability"]))
			population_peak = maxi(population_peak, int(s["population"]))
			condition_min = minf(condition_min, float(s["min_condition"]))
			incident_hours += float(int(s["open_incidents"]))
			net_sum += float(s["net"])
			blackout_total += float(s["blackout_minutes"])
			metered_minutes += 60.0 * float(int(s["metered_buildings"]))
			settled_hours += 1
		return {
			"days": opts.days,
			"hours": opts.hours(),
			"treasury_start": int(first["treasury"]),
			"treasury_end": int(last["treasury"]),
			"treasury_min": treasury_min,
			"treasury_max": treasury_max,
			"net_first_hour": float(samples[1]["net"]) if samples.size() > 1 else 0.0,
			"net_last_hour": float(last["net"]),
			"net_mean_per_hour": net_sum / maxf(1.0, float(settled_hours)),
			"population_start": int(first["population"]),
			"population_end": int(last["population"]),
			"population_peak": population_peak,
			"happiness_end": float(last["happiness"]),
			"happiness_min": happiness_min,
			"stability_end": float(last["stability"]),
			"stability_min": stability_min,
			"city_level_end": int(last["city_level"]),
			"goal_level_end": int(last.get("goal_level", 0)),
			"water_placed": api.water_placed,
			"water_spend": api.water_spend,
			## Doc 92 §17.6's other half: the tiles a strategy laid ITSELF,
			## separate from doc 09's block template, and what they cost.
			"road_tiles_built": api.road_tiles_built,
			"road_spend": api.road_spend,
			"blackout_minutes_total": blackout_total,
			## Fraction of all building-time spent without power — the shape of
			## `blackout_minutes_total` normalised by how big the city got.
			"unserved_share": blackout_total / maxf(1.0, metered_minutes),
			"dark_buildings_end": int(last["dark_buildings"]),
			"buildings_start": int(first["buildings"]),
			"buildings_end": int(last["buildings"]),
			"placed": api.placed,
			"upgraded": api.upgraded,
			"construction_spend": api.construction_spend,
			"actions": api.actions.size(),
			"reason_codes": _sorted_counts(api.reason_codes),
			"deferred_liability_end": sim.treasury.deferred_liability,
			"austerity_active_end": sim.treasury.austerity_active,
			"credit_limit_end": sim.treasury.credit_limit,
			"lifetime": _sorted_counts(sim.treasury.lifetime),
			"day_rows": _day_rows(samples),
			# --- pass 2 ---------------------------------------------------
			## Cash plus everything the agent turned into buildings. Spend-
			## everything agents pin the treasury near zero, so cash alone ranks
			## them wrongly; this is the column the headline table sorts on.
			"value_created": int(last["treasury"]) + api.construction_spend,
			"grid_placed": api.grid_placed,
			"grid_spend": api.grid_spend,
			# --- Wave 6: the trunk half of the grid decision -----------------
			"feeders_routed": api.feeders_routed,
			"feeder_spend": api.feeder_spend,
			"feeder_adopted_kw": api.feeder_adopted_kw,
			"substations_built": api.substations_built,
			## The reading `FEEDER_RELIEF_RATIO` gates on, at the end of the run:
			## doc 92 §17.3's ceiling, published as a column so a report row can
			## say whether the city ended over its own trunk.
			"feeder_peak_ratio_end": float(sim.grid.worst_feeder(
					float(sim.weather.env_for_grid().get("t_ambient_c", 25.0)))["load_ratio"]),
			# --- Wave 24: the POOL, one level above the trunk (doc 92 §63.3) --
			## Every founded city starts on doc 04 §2.2's one L1 gas plant —
			## **8,000 kW, and nothing else generates** — and until this wave no
			## strategy in this file ever bought or upgraded generation. These
			## two columns are what let a report row say whether a city that
			## went dark had run out of POWER or run out of COPPER; they are
			## different failures and gate 18b's single share cannot tell them
			## apart. See `Balanced.GENERATION_RELIEF_RATIO`.
			"supply_kw_end": float(sim.grid.capacity_summary()["supply_kw"]),
			"demand_kw_end": float(sim.grid.capacity_summary()["demand_kw"]),
			"repaired": api.repaired,
			"repair_spend": api.repair_spend,
			"demolished": api.demolished,
			"demolition_refund": api.demolition_refund,
			"blocks_bought": api.blocks_bought,
			"land_spend": api.land_spend,
			"tax_changes": api.tax_changes,
			"priority_sets": api.priority_sets,
			"unserved_walls": api.unserved_walls,
			# --- Wave 15: doc 06 §2.16's tap on an arc (RR-86) --------------
			"opportunities_collected": api.opportunities_collected,
			"street_income": api.street_income,
			"street_missed": api.street_missed,
			## THE NUMBER doc 92 §35.3 could not take: street bounties as a share
			## of the same run's settled net. `0.0` for every agent that never
			## taps, which is the "and exactly 0 when idle" half of doc 03 §2.5's
			## ruling measured rather than asserted.
			"street_share_of_net": float(api.street_income)
					/ maxf(1.0, net_sum),
			## `city_level` -> `{n, dollars}`. Doc 92 §35.3's question 4:
			## `STREET_REWARD_CITY_LEVEL_K` against a level-4+ city.
			"street_by_level": api.street_by_level.duplicate(true),
			"tax_rate_end": float(last["tax_rate"]),
			"tax_level_end": sim.tax_level(),
			"blocks_owned_end": int(last["blocks_owned"]),
			"min_condition": condition_min,
			"min_condition_end": float(last["min_condition"]),
			"mean_condition_end": float(last["mean_condition"]),
			"damaged_end": int(last["damaged_buildings"]),
			"destroyed_end": int(last["destroyed_buildings"]),
			"failed_components_end": int(last["failed_components"]),
			## Σ open incidents over every sampled hour ÷ hours — "how many fires
			## were burning at any moment", which is the number a neglectful city
			## is supposed to drive up.
			"open_incidents_mean": incident_hours / maxf(1.0, float(settled_hours)),
		}

	## One row per game-day: the end-of-day state plus that day's mean net and
	## total blackout minutes. This is what doc 92's tables are built from.
	static func _day_rows(samples: Array[Dictionary]) -> Array[Dictionary]:
		var rows: Array[Dictionary] = []
		var net_sum := 0.0
		var blackout_sum := 0.0
		var counted := 0
		for i in range(1, samples.size()):
			var s: Dictionary = samples[i]
			net_sum += float(s["net"])
			blackout_sum += float(s["blackout_minutes"])
			counted += 1
			if int(s["h"]) % HOURS_PER_DAY != 0:
				continue
			rows.append({
				"day": int(s["h"]) / HOURS_PER_DAY,
				"treasury": int(s["treasury"]),
				"net_mean_per_hour": net_sum / maxf(1.0, float(counted)),
				"population": int(s["population"]),
				"happiness": float(s["happiness"]),
				"stability": float(s["stability"]),
				"city_level": int(s["city_level"]),
				"goal_level": int(s.get("goal_level", 0)),
				"blackout_minutes": blackout_sum,
				"buildings": int(s["buildings"]),
				"min_condition": float(s["min_condition"]),
				"damaged_buildings": int(s["damaged_buildings"]),
				"open_incidents": int(s["open_incidents"]),
				"failed_components": int(s["failed_components"]),
				"blocks_owned": int(s["blocks_owned"]),
			})
			net_sum = 0.0
			blackout_sum = 0.0
			counted = 0
		return rows

	# --- plumbing -----------------------------------------------------------

	static func _boot_errors(sim: CitySim) -> Array:
		var out: Array = []
		for message in sim.boot_errors:
			out.append(String(message))
		return out

	static func _verb_map(api: Api) -> Dictionary:
		var out := {}
		for verb in KNOWN_VERBS:
			out[verb] = bool(api.verbs[verb]["present"])
		return out

	static func _sorted_counts(dict: Dictionary) -> Dictionary:
		var keys := dict.keys()
		keys.sort()
		var out := {}
		for key in keys:
			out[key] = dict[key]
		return out

	## SHA-256 over the full-precision sample stream. Two runs of the same
	## seed+strategy+mode must produce the same digest — that is the harness's
	## own determinism gate, independent of the sim's `state_hash()`.
	static func _digest(samples: Array[Dictionary]) -> String:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(JSON.stringify(samples, "", true, true).to_utf8_buffer())
		return ctx.finish().hex_encode()


# ===========================================================================
# Controlled micro-experiments
# ===========================================================================

## A strategy run answers "what happens when someone plays like this". It cannot
## answer "what does ONE transformer buy" or "what does ONE tax detent cost",
## because a strategy moves a dozen things at once. These do: each boots a fresh
## city per data point, moves exactly one variable, runs the same number of
## game-hours on the same seed, and prints a markdown table.
##
## They are measurements, not tests — nothing here asserts, and nothing here
## reads a balance constant the report then quotes back as its own finding.
class Experiments extends RefCounted:
	const NAMES: Array[String] = ["transformer_payback", "tax_curve"]
	## Long enough for a house to finish construction and its occupancy ramp
	## (doc 03 §8 `OCCUPANCY_RAMP_HOURS` 36) to settle, short enough to run 20 of
	## them: the payback probe measures a STEADY net, not a construction dip.
	const PAYBACK_SETTLE_HOURS := 72
	const PAYBACK_MEASURE_HOURS := 24
	const TAX_CURVE_HOURS := 7 * HOURS_PER_DAY

	static func run(name: String, opts: Options) -> void:
		match name:
			"transformer_payback":
				transformer_payback(opts)
			"tax_curve":
				tax_curve(opts)

	# ------------------------------------------------------------------------

	## What does the `E_UNSERVED` wall cost to knock down, and how fast does the
	## ground behind it pay the bill back?
	##
	## Per seed: boot a treated city and an untouched twin of it. The treated
	## city buys ONE L1 transformer on the tile that lights the most dark ground,
	## then buys houses on exactly the tiles that tap lit — never on ground that
	## was already served, so every dollar of the difference is attributable to
	## the tap. Both cities then run the same hours and their settled net $/gh is
	## compared. Payback is the outlay divided by that difference.
	##
	## Two paybacks are reported because they answer different questions: **tap
	## only** is what the grid verb itself costs to earn back (is the transformer
	## priced right?), and **total** includes the houses (is the expansion worth
	## doing at all?).
	static func transformer_payback(opts: Options) -> void:
		print("")
		print("## transformer payback — doc 04 §2.1 / doc 03 §2.13(b), %s path"
				% opts.mode)
		print("")
		print("| seed | tap tile | tap $ | lateral tiles | tiles lit | houses | house $ "
				+ "| total outlay | Δ net $/gh | tap payback (gh) | total payback (gh) "
				+ "| total payback (game-days) |")
		print("|---|---|---|---|---|---|---|---|---|---|---|---|")
		for seed_value in opts.seeds:
			var row := _payback_once(seed_value, opts.mode == "coarse")
			if row.is_empty():
				print("| %d | _no placeable unserved tile_ |||||||||||" % seed_value)
				continue
			var delta := float(row["delta_net"])
			var tap_payback := "never"
			var total_payback := "never"
			var total_days := "never"
			if delta > 0.0:
				tap_payback = "%.0f" % (float(row["tap_cost"]) / delta)
				var hours := float(row["outlay"]) / delta
				total_payback = "%.0f" % hours
				total_days = "%.1f" % (hours / float(HOURS_PER_DAY))
			print("| %d | (%d,%d) | %s | %d | %d | %d | %s | %s | %+.2f | %s | %s | %s |" % [
					seed_value, int(row["tile_x"]), int(row["tile_z"]),
					Fmt.thousands(int(row["tap_cost"])),
					int(row["lateral"]), int(row["lit"]), int(row["houses"]),
					Fmt.thousands(int(row["house_cost"])),
					Fmt.thousands(int(row["outlay"])), delta,
					tap_payback, total_payback, total_days])
		print("")
		_tap_price_ladder(opts.seeds[0])

	## The price of the verb itself, as a function of how far the tile sits from
	## a feeder. Doc 03 §2.13(b): `transformer` L1 build cost + one feeder
	## lateral per Chebyshev tile at that feeder's conductor price. Previews
	## only — nothing is charged and no city is advanced, so this is a pure read
	## of the price table through the command layer that quotes it.
	static func _tap_price_ladder(seed_value: int) -> void:
		var sim := CitySim.boot_from_files(seed_value)
		var api := Api.new(sim)
		var by_distance := {}
		for tile in api.unserved_tiles():
			var quote: Dictionary = api.grid_quote("transformer", tile)
			var payload: Dictionary = quote["payload"]
			if not payload.has("lateral_tiles"):
				continue
			var distance := int(payload["lateral_tiles"])
			if by_distance.has(distance):
				continue
			by_distance[distance] = {"cost": int(payload["cost"]),
					"tile": tile, "ok": bool(quote["ok"]),
					"reason": String(quote["reason_code"])}
		var distances: Array = by_distance.keys()
		distances.sort()
		print("## L1 transformer tap price by lateral distance (seed %d, preview only)"
				% seed_value)
		print("")
		print("| lateral tiles | tap price | example tile | preview |")
		print("|---|---|---|---|")
		for distance in distances:
			var row: Dictionary = by_distance[distance]
			var tile: Vector2i = row["tile"]
			print("| %d | %s | (%d,%d) | %s |" % [int(distance),
					Fmt.thousands(int(row["cost"])), tile.x, tile.y,
					"ok" if bool(row["ok"]) else String(row["reason"])])
		print("")

	static func _payback_once(seed_value: int, coarse: bool) -> Dictionary:
		var control := CitySim.boot_from_files(seed_value)
		var treated := CitySim.boot_from_files(seed_value)
		var api := Api.new(treated)
		var tile := api.best_transformer_tile()
		if tile.x < 0:
			return {}
		var before := api.unserved_tiles()
		# 1. Quote it (free — nothing is charged on a preview), then buy it.
		var quote: Dictionary = api.grid_quote("transformer", tile)
		if not bool(quote["ok"]):
			return {}
		var quoted: Dictionary = quote["payload"]
		if not bool(api.place_grid_component("transformer", tile)["ok"]):
			return {}
		# 2. The tiles that stopped being unserved are exactly what the tap lit.
		# Its own tile is reserved by the command (doc 04 §2.1) and is excluded.
		var still_dark := {}
		for t in api.unserved_tiles():
			still_dark[Api._tile_key(t)] = true
		var lit_tiles: Array[Vector2i] = []
		for t in before:
			if t != tile and not still_dark.has(Api._tile_key(t)):
				lit_tiles.append(t)
		# 3. Buy that ground, and only that ground.
		var houses := 0
		var house_cost := 0
		for t in lit_tiles:
			if api.balance() < api.build_cost("house"):
				break
			var balance_before := api.balance()
			if not bool(api.place_at("house", t)["ok"]):
				continue
			houses += 1
			house_cost += balance_before - api.balance()
		# 4. Run both cities the same hours and compare STEADY net.
		var control_net := _settled_net(control, coarse)
		var treated_net := _settled_net(treated, coarse)
		return {
			"tile_x": tile.x, "tile_z": tile.y,
			"tap_cost": int(quoted.get("cost", 0)),
			"lateral": int(quoted.get("lateral_tiles", 0)),
			"lit": lit_tiles.size(),
			"houses": houses,
			"house_cost": house_cost,
			"outlay": int(quoted.get("cost", 0)) + house_cost,
			"delta_net": treated_net - control_net,
		}

	## Mean settled net $/gh over `PAYBACK_MEASURE_HOURS`, after letting
	## construction and the occupancy ramp finish.
	static func _settled_net(sim: CitySim, coarse: bool) -> float:
		_advance(sim, PAYBACK_SETTLE_HOURS, coarse)
		sim.bus.drain()
		var total := 0.0
		for i in PAYBACK_MEASURE_HOURS:
			_advance(sim, 1, coarse)
			for event in sim.bus.drain():
				if String(event["type"]) == "economy_hour_settled":
					total += float(event.get("net", 0.0))
		return total / float(PAYBACK_MEASURE_HOURS)

	static func _advance(sim: CitySim, hours: int, coarse: bool) -> void:
		if coarse:
			sim.advance_coarse_hours(hours)
		else:
			sim.advance_hours(float(hours))

	# ------------------------------------------------------------------------

	## Every detent of doc 03 §8's tax ladder, one week each, same seed, same
	## `do_nothing` city. The only thing that differs between rows is `r`, so the
	## columns ARE doc 03 §2.2's three published consequences: revenue scalar,
	## happiness shift and growth multiplier — measured, not quoted.
	static func tax_curve(opts: Options) -> void:
		var probe := CitySim.boot_from_files(opts.seeds[0])
		var levels := probe.tax_level_count()
		print("")
		print("## tax ladder — doc 03 §2.2 / §8, %d detents, %d game-days each, seed %d, %s path"
				% [levels, TAX_CURVE_HOURS / HOURS_PER_DAY, opts.seeds[0], opts.mode])
		print("")
		print("| level | rate | policy factor | published Δhappy | published growth× "
				+ "| treasury | net $/gh | pop | happiness | stability |")
		print("|---|---|---|---|---|---|---|---|---|---|")
		for level in levels:
			var sim := CitySim.boot_from_files(opts.seeds[0])
			var result: Dictionary = sim.cmd_set_tax_level(level)
			if not bool(result["ok"]):
				print("| %d | _%s_ |||||||||" % [level, String(result["reason_code"])])
				continue
			var payload: Dictionary = result["payload"]
			var net := 0.0
			var settled := 0
			sim.bus.drain()
			for i in TAX_CURVE_HOURS:
				_advance(sim, 1, opts.mode == "coarse")
				for event in sim.bus.drain():
					if String(event["type"]) == "economy_hour_settled":
						net += float(event.get("net", 0.0))
						settled += 1
			print("| %d | %.2f | %.4f | %+.2f | %.3f | %s | %.1f | %d | %.1f | %.4f |" % [
					level, float(payload["rate"]),
					sim.economy.tax_policy_factor(float(payload["rate"])),
					float(payload["happiness_delta"]), float(payload["growth_multiplier"]),
					Fmt.thousands(sim.treasury.balance), net / maxf(1.0, float(settled)),
					sim.population.city_population, sim.happiness.happiness,
					sim.districts.city_stability])
		print("")


# ===========================================================================
# Terminal table
# ===========================================================================

class Table extends RefCounted:

	static func print_all(runs: Array[Dictionary], opts: Options) -> void:
		if runs.is_empty():
			return
		print("")
		print("=".repeat(118))
		print("SLACUM CITY balance harness — %d game-days, %s path, %s difficulty, seeds %s"
				% [opts.days, opts.mode, opts.difficulty, ", ".join(_seed_strings(opts))])
		print("=".repeat(118))
		var verbs: Dictionary = runs[0]["verbs"]
		var present: Array[String] = []
		var missing: Array[String] = []
		for verb in KNOWN_VERBS:
			if bool(verbs.get(verb, false)):
				present.append(verb)
			else:
				missing.append(verb)
		print("command layer: %s" % ", ".join(present))
		if not missing.is_empty():
			print("      missing: %s  (doc 93 §B — strategies degrade around these)"
					% ", ".join(missing))
		print("")
		print("%-20s %6s %10s %11s %8s %6s %6s %7s %4s %6s %5s %4s %4s %4s %4s %5s" % [
				"strategy", "seed", "treasury", "value", "net/gh", "pop", "happy",
				"stab", "lvl", "dark%", "built", "upg", "xfmr", "rep", "land", "cond"])
		print("-".repeat(118))
		var by_strategy := {}
		for report in runs:
			var s: Dictionary = report["summary"]
			var run_info: Dictionary = report["run"]
			var strategy_id := String(run_info["strategy"])
			if not by_strategy.has(strategy_id):
				by_strategy[strategy_id] = []
			(by_strategy[strategy_id] as Array).append(s)
			print("%-20s %6d %10s %11s %8.1f %6d %6.1f %7.4f %4d %6.2f %5d %4d %4d %4d %4d %5.2f" % [
					strategy_id, int(run_info["seed"]),
					Fmt.thousands(int(s["treasury_end"])), Fmt.thousands(int(s["value_created"])),
					float(s["net_mean_per_hour"]), int(s["population_end"]),
					float(s["happiness_end"]), float(s["stability_end"]),
					int(s["city_level_end"]), 100.0 * float(s["unserved_share"]),
					int(s["placed"]), int(s["upgraded"]), int(s["grid_placed"]),
					int(s["repaired"]), int(s["blocks_bought"]),
					float(s["min_condition"])])
		print("-".repeat(118))
		for strategy_id in STRATEGY_IDS:
			if not by_strategy.has(strategy_id):
				continue
			var rows: Array = by_strategy[strategy_id]
			print("%-20s %6s %10s %11s %8.1f %6.0f %6.1f %7.4f %4.1f %6.2f %5.1f %4.1f %4.1f %4.1f %4.1f %5.2f" % [
					("~mean " + strategy_id).substr(0, 20), "-",
					Fmt.thousands(int(_mean(rows, "treasury_end"))),
					Fmt.thousands(int(_mean(rows, "value_created"))),
					_mean(rows, "net_mean_per_hour"), _mean(rows, "population_end"),
					_mean(rows, "happiness_end"), _mean(rows, "stability_end"),
					_mean(rows, "city_level_end"), 100.0 * _mean(rows, "unserved_share"),
					_mean(rows, "placed"), _mean(rows, "upgraded"),
					_mean(rows, "grid_placed"), _mean(rows, "repaired"),
					_mean(rows, "blocks_bought"), _mean(rows, "min_condition")])
		print("=".repeat(118))
		_print_day_curve(runs)
		_print_events(runs)
		_print_reasons(runs)

	## Sim events worth a designer's attention, summed per strategy: grid
	## failures, blackout transitions, progression moments, money-trouble flags.
	static func _print_events(runs: Array[Dictionary]) -> void:
		const WATCH: Array[String] = [
			"PowerComponentFailed", "PowerComponentTripped", "BuildingPowerChanged:DARK",
			"BlockDarkChanged", "city_level_changed", "credit_line_engaged",
			"deferred_liability_accrued", "building_completed",
			"incident_created", "incident_resolved", "incident_failed",
			"incident_abandoned", "unit_dispatched", "director_event_started",
			"power_restored_by_repair", "water_pressure_low", "water_main_isolated",
			"grid_component_placed", "block_purchased", "tax_rate_changed",
		]
		var by_strategy := {}
		for report in runs:
			var run_info: Dictionary = report["run"]
			var events: Dictionary = report["events"]
			var strategy_id := String(run_info["strategy"])
			var bucket: Dictionary = by_strategy.get(strategy_id, {})
			for key in events:
				bucket[key] = int(bucket.get(key, 0)) + int(events[key])
			by_strategy[strategy_id] = bucket
		print("")
		print("sim events by strategy (all seeds)")
		for strategy_id in STRATEGY_IDS:
			if not by_strategy.has(strategy_id):
				continue
			var bucket: Dictionary = by_strategy[strategy_id]
			var parts: Array[String] = []
			for key in WATCH:
				if bucket.has(key):
					parts.append("%s=%d" % [key, int(bucket[key])])
			print("  %-20s %s" % [strategy_id, ", ".join(parts) if not parts.is_empty() else "-"])

	## The treasury curve, one column per strategy, at day granularity — the
	## snowball question answered at a glance.
	static func _print_day_curve(runs: Array[Dictionary]) -> void:
		var columns: Array[String] = []
		var series := {}
		for report in runs:
			var run_info: Dictionary = report["run"]
			var summary: Dictionary = report["summary"]
			var strategy_id := String(run_info["strategy"])
			if not series.has(strategy_id):
				series[strategy_id] = {}
				columns.append(strategy_id)
			var bucket: Dictionary = series[strategy_id]
			for row_variant in summary["day_rows"]:
				var row: Dictionary = row_variant
				var day := int(row["day"])
				bucket[day] = float(bucket.get(day, 0.0)) + float(row["treasury"])
		var seeds_per_strategy := float(runs.size()) / maxf(1.0, float(columns.size()))
		print("")
		print("mean treasury by game-day ($)")
		var header := "%5s" % "day"
		for column in columns:
			header += " %20s" % column
		print(header)
		var days: Array = (series[columns[0]] as Dictionary).keys()
		days.sort()
		for day in days:
			var line := "%5d" % int(day)
			for column in columns:
				line += " %20s" % Fmt.thousands(int(
						float((series[column] as Dictionary).get(day, 0.0)) / seeds_per_strategy))
			print(line)

	## Every reason code the command layer returned, by strategy — the wall map.
	static func _print_reasons(runs: Array[Dictionary]) -> void:
		var by_strategy := {}
		for report in runs:
			var run_info: Dictionary = report["run"]
			var summary: Dictionary = report["summary"]
			var codes: Dictionary = summary["reason_codes"]
			var strategy_id := String(run_info["strategy"])
			var bucket: Dictionary = by_strategy.get(strategy_id, {})
			for reason in codes:
				bucket[reason] = int(bucket.get(reason, 0)) + int(codes[reason])
			by_strategy[strategy_id] = bucket
		print("")
		print("command results by strategy (all seeds)")
		for strategy_id in STRATEGY_IDS:
			if not by_strategy.has(strategy_id):
				continue
			var bucket: Dictionary = by_strategy[strategy_id]
			var keys: Array = bucket.keys()
			keys.sort()
			var parts: Array[String] = []
			for key in keys:
				parts.append("%s=%d" % [String(key), int(bucket[key])])
			print("  %-20s %s" % [strategy_id, ", ".join(parts) if not parts.is_empty() else "-"])
		print("")

	static func _seed_strings(opts: Options) -> Array[String]:
		var out: Array[String] = []
		for seed_value in opts.seeds:
			out.append(str(seed_value))
		return out

	static func _mean(rows: Array, key: String) -> float:
		var total := 0.0
		for row in rows:
			total += float((row as Dictionary)[key])
		return total / maxf(1.0, float(rows.size()))
