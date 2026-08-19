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
##                       tax_squeezer|disaster_neglect|all
##   --mode=fine|coarse  fine = the online 4 Hz path (what the player plays);
##                       coarse = doc 01's 1-game-hour offline catch-up path
##                                (~60x faster, and NOT the same city — see
##                                docs/design/92-balance-report.md)   (default fine)
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

## Report order, not alphabetical: the control first, then the four players, then
## the two single-variable variants of `balanced` (see the class comments —
## `tax_squeezer` and `disaster_neglect` differ from `balanced` in exactly one
## knob each, which is what makes their curves readable as a cause).
const STRATEGY_IDS: Array[String] = [
	"do_nothing", "greedy_growth", "infrastructure_first", "balanced",
	"tax_squeezer", "disaster_neglect",
]

## Verbs the harness knows how to drive. Present ones are used, absent ones are
## recorded and skipped. As of Wave 1.5 every one of these exists; the probe
## stays because it is what keeps a mid-wave harness from crashing.
const KNOWN_VERBS: Array[String] = [
	"cmd_place_building", "cmd_upgrade_building", "cmd_repair_building",
	"cmd_demolish_building", "cmd_buy_block", "cmd_start_development",
	"cmd_set_tax_level", "cmd_set_priority", "cmd_place_grid_component",
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
				var path: String = "%s/%s_seed%d_d%d_%s.json" % [
						opts.out_dir, strategy_id, seed_value, opts.days, opts.mode]
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
							if not STRATEGY_IDS.has(name):
								opts.errors.append("unknown strategy '%s' (have %s)"
										% [name, ", ".join(STRATEGY_IDS)])
							else:
								opts.strategies.append(name)
				"mode":
					if value != "fine" and value != "coarse":
						opts.errors.append("--mode must be fine or coarse")
					else:
						opts.mode = value
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
	var demolished: int = 0
	var demolition_refund: int = 0
	var blocks_bought: int = 0
	var land_spend: int = 0
	var tax_changes: int = 0
	var priority_sets: int = 0
	## `cmd_place_building` answers `E_UNSERVED`: the wall a player without a
	## transformer runs into. Counting it is the whole point of `greedy_growth`.
	var unserved_walls: int = 0

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

	## Every upgradeable building, cheapest first, id tie-break. Each entry is
	## `{sim_id, cost, level, archetype}`; only clear-gate rows are returned.
	func upgrade_candidates(categories: Array = []) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if not has_verb("cmd_upgrade_building"):
			return out
		for id in _sorted(sim.buildings):
			var sim_id := String(id)
			var b: Building = sim.buildings[sim_id]
			if b.state != &"active" or b.level >= 5:
				continue
			var archetype := String(b.archetype)
			if not categories.is_empty() and not categories.has(sim.catalog.category(archetype)):
				continue
			var preview := upgrade_preview(sim_id)
			if not bool(preview["ok"]):
				continue
			out.append({"sim_id": sim_id, "archetype": archetype, "level": b.level,
					"cost": int(preview["payload"].get("cost", 0))})
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["cost"]) != int(b["cost"]):
				return int(a["cost"]) < int(b["cost"])
			return String(a["sim_id"]) < String(b["sim_id"]))
		return out

	# --- the doc 93 §B verbs ------------------------------------------------

	func repair(sim_id: String) -> Dictionary:
		var result := _optional("cmd_repair_building", 1, [sim_id], sim_id)
		if bool(result["ok"]):
			repaired += 1
			repair_spend += int((result["payload"] as Dictionary).get("cost", 0))
		return result

	func demolish(sim_id: String) -> Dictionary:
		var result := _optional("cmd_demolish_building", 1, [sim_id], sim_id)
		if bool(result["ok"]):
			demolished += 1
			demolition_refund += int((result["payload"] as Dictionary).get("refund", 0))
		return result

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

	## Doc 93 §B's headline verb ("THE game"). `cmd_place_grid_component(kind,
	## tile, level = 1, preview = false)` — the harness only ever buys L1, which
	## is the rung the `E_UNSERVED` wall is actually priced against.
	func place_grid_component(kind: String, tile: Vector2i) -> Dictionary:
		var result := _optional("cmd_place_grid_component", 2, [kind, tile],
				"%s@%d,%d" % [kind, tile.x, tile.y])
		if bool(result["ok"]):
			grid_placed += 1
			grid_spend += int((result["payload"] as Dictionary).get("cost", 0))
		return result

	## The same command's read-only quote. Costs no money and no log line — the
	## price probe `Experiments.transformer_payback` reads the $ figure from here.
	func grid_quote(kind: String, tile: Vector2i) -> Dictionary:
		if not has_verb("cmd_place_grid_component"):
			return CommandQueue.fail(&"E_NO_VERB")
		return sim.cmd_place_grid_component(kind, tile, 1, true)

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

	var _grid_attempt_hour: int = -1000
	var _land_attempt_hour: int = -1000

	func id() -> String:
		return "infrastructure_first"

	func describe() -> String:
		return "repairs, buys grid ahead of growth and land ahead of both"

	func act(api: Api, hour: int) -> void:
		if _repair_something(api):
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
## standing before adding more, add one civic building per city level, keep the
## city in repair, and expand outward when the war chest allows.
##
## Two knobs on this class are the whole design of pass 2's new strategies.
## `tax_squeezer` and `disaster_neglect` are this agent with ONE of them moved,
## so any difference in their curves is attributable to that knob and nothing
## else — a controlled pair, not two more bots.
class Balanced extends Strategy:
	const RESERVE_FLOOR := 12_000
	const RESERVE_DAYS_OF_EXPENSE := 1.0
	const RESIDENTIAL_PER_COMMERCIAL := 2
	const REVENUE: Array[String] = ["residential", "commercial", "industrial"]
	const INFRA: Array[String] = ["service", "utility"]
	## Upgrades are cheaper per point of yield than new floorspace, so take one
	## whenever the reserve allows — but never more than one action per hour.
	const UPGRADE_HEADROOM := 2.0

	## Expansion: a competent player buys the next block when the war chest can
	## absorb both the purchase and the development bill (doc 03 §2.7/§2.8).
	const EXPAND_SURPLUS := 80_000
	const EXPAND_COOLDOWN := 24

	## Maintenance (doc 02 §2.6): repair below this condition, worst first, and
	## give the civic roster a shed-proof priority class once (doc 04 §2.4).
	const REPAIR_THRESHOLD := 0.90
	const CIVIC_PRIORITY := "ESSENTIAL"
	## A transformer only when the served ground has actually run out — a
	## competent player reacts to the wall, they do not pre-buy against it the
	## way `infrastructure_first` does.
	const GRID_COOLDOWN := 8

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
	var _tax_hour: int = -1000
	var _priorities_set: bool = false

	func id() -> String:
		return "balanced"

	func describe() -> String:
		return "2:1 residential:commercial, 1-day reserve, upgrade-first, maintained"

	func note_expense(expense_per_hour: float) -> void:
		_last_expense_per_hour = expense_per_hour

	func reserve() -> int:
		return maxi(RESERVE_FLOOR,
				int(RESERVE_DAYS_OF_EXPENSE * 24.0 * _last_expense_per_hour))

	func act(api: Api, hour: int) -> void:
		# Policy first: it is free (doc 03 prices no rate change beyond its
		# consequences) and it must be in force before the first settlement the
		# report reads.
		if _hold_tax(api, hour):
			return
		if maintains:
			if _set_civic_priorities(api):
				return
			if _repair_something(api):
				return
		var spare := api.balance() - reserve()
		if spare <= 0:
			return
		# 0. Expand outward when the war chest allows.
		if _expand(api, hour, spare):
			return
		# 0b. Buy the transformer the wall is asking for.
		if maintains and _unwall(api, hour, spare):
			return
		# 1. One civic building each time the city levels up.
		if api.city_level() > _civic_at_level:
			var civic := _cheapest(api, INFRA)
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

	func _expand(api: Api, hour: int, spare: int) -> bool:
		if not api.has_verb("cmd_buy_block"):
			return false
		if hour - _expand_hour < EXPAND_COOLDOWN or spare < EXPAND_SURPLUS:
			return false
		var block_id := api.purchasable_block()
		if block_id == "":
			return false
		_expand_hour = hour
		return bool(api.buy_block(block_id)["ok"])

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

	func _repair_something(api: Api) -> bool:
		if not api.has_verb("cmd_repair_building"):
			return false
		var queue := api.maintenance_queue(REPAIR_THRESHOLD)
		if queue.is_empty():
			return false
		return bool(api.repair(String(queue[0]["sim_id"]))["ok"])

	## The reactive half of the grid verb: when there is no served site left for
	## the archetype this agent wants, buy the tap that opens the most ground.
	func _unwall(api: Api, hour: int, spare: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if hour - _grid_hour < GRID_COOLDOWN or spare <= 0:
			return false
		if api.candidate_site(Vector2i.ONE).x >= 0:
			return false  # served ground still available; nothing to unwall
		var tile := api.best_transformer_tile()
		if tile.x < 0:
			return false
		_grid_hour = hour
		return bool(api.place_grid_component("transformer", tile)["ok"])

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


class Factory extends RefCounted:

	static func make(strategy_id: String) -> Strategy:
		match strategy_id:
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
		return null


# ===========================================================================
# The run loop
# ===========================================================================

class Runner extends RefCounted:

	## One run: boot, drive, sample, summarise. Returns the JSON document.
	static func run_one(strategy_id: String, seed_value: int, opts: Options) -> Dictionary:
		var sim := CitySim.boot_from_files(seed_value)
		var strategy := Factory.make(strategy_id)
		var api := Api.new(sim)
		var total_hours := opts.hours()
		var samples: Array[Dictionary] = []
		var events: Dictionary = {}
		var coarse := opts.mode == "coarse"

		# Founding sample (hour 0) so every curve starts from a stated t0.
		sim.bus.drain()
		samples.append(_sample(sim, 0, {}, 0.0))

		for h in total_hours:
			api.hour = h
			strategy.act(api, h)
			if coarse:
				sim.advance_coarse_hours(1)
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
			"population": sim.population.city_population,
			"happiness": sim.happiness.happiness,
			"stability": sim.districts.city_stability,
			"city_level": sim.progression.city_level,
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
			"repaired": api.repaired,
			"repair_spend": api.repair_spend,
			"demolished": api.demolished,
			"demolition_refund": api.demolition_refund,
			"blocks_bought": api.blocks_bought,
			"land_spend": api.land_spend,
			"tax_changes": api.tax_changes,
			"priority_sets": api.priority_sets,
			"unserved_walls": api.unserved_walls,
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
		print("SLACUM CITY balance harness — %d game-days, %s path, seeds %s"
				% [opts.days, opts.mode, ", ".join(_seed_strings(opts))])
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
