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
##   --days=N            game-days per run                    (default 14)
##   --seeds=a,b,c       RNG seeds, one run each              (default 1337,4242,9001)
##   --strategies=a,b    do_nothing|greedy_growth|infrastructure_first|balanced|all
##   --mode=fine|coarse  fine = the online 4 Hz path (what the player plays);
##                       coarse = doc 01's 1-game-hour offline catch-up path
##                                (~68x faster, and NOT the same city — see
##                                docs/design/92-balance-report.md)   (default fine)
##   --out=DIR           output directory              (default res://build/playtest)
##   --no-json           terminal table only
##   --quiet             suppress the per-run progress lines
##
## Determinism: the harness makes no stochastic choices. Site selection scans
## sorted block ids and row-major tiles; archetype preference lists are sorted
## with an id tie-break; every dictionary iterated for output is sorted. Same
## seed + same strategy + same mode ⇒ byte-identical sample stream (asserted by
## `tests/test_playtest_harness.gd`).

const SCHEMA_VERSION := 1
const DEFAULT_DAYS := 14
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const DEFAULT_OUT_DIR := "res://build/playtest"
const HOURS_PER_DAY := 24

const STRATEGY_IDS: Array[String] = [
	"do_nothing", "greedy_growth", "infrastructure_first", "balanced",
]

## Verbs the harness knows how to drive. Present ones are used, absent ones are
## recorded and skipped — doc 93 §B is being implemented in parallel, so this
## list is deliberately ahead of `sim/city_sim.gd`.
const KNOWN_VERBS: Array[String] = [
	"cmd_place_building", "cmd_upgrade_building", "cmd_repair_building",
	"cmd_demolish_building", "cmd_buy_block", "cmd_set_tax_level",
	"cmd_set_priority", "cmd_place_grid_component",
]


func _initialize() -> void:
	var opts := Options.parse(OS.get_cmdline_user_args())
	if not opts.errors.is_empty():
		for message in opts.errors:
			printerr("playtest: " + message)
		quit(2)
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

	var sim: CitySim
	var hour: int = 0
	var actions: Array[Dictionary] = []
	var reason_codes: Dictionary = {}
	var placed: int = 0
	var upgraded: int = 0
	var construction_spend: int = 0

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

	## The first buildable tile in an owned+READY block that NO transformer
	## reaches — i.e. where `cmd_place_building` answers `E_UNSERVED`. This is
	## where a grid-extension verb would want to drop a transformer.
	func unserved_site() -> Vector2i:
		for block_id in _ready_blocks():
			var block: LandBlock = sim.world.block(block_id)
			var x0: int = block.grid.x * BLOCK_TILES
			var z0: int = block.grid.y * BLOCK_TILES
			for z in range(z0, z0 + BLOCK_TILES):
				for x in range(x0, x0 + BLOCK_TILES):
					var tile := Vector2i(x, z)
					if sim.world.grid.can_place(tile, Vector2i.ONE) \
							and not sim.grid.would_serve(tile):
						return tile
		return Vector2i(-1, -1)

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
	## (plus a `site` key) so the strategy can read reason codes.
	func place(archetype: String) -> Dictionary:
		if not has_verb("cmd_place_building"):
			return _log("place", archetype, CommandQueue.fail(&"E_NO_VERB"), {})
		var size := footprint(archetype)
		var origin := candidate_site(size)
		if origin.x < 0:
			return _log("place", archetype, CommandQueue.fail(&"E_NO_SITE"), {})
		var result: Dictionary = sim.cmd_place_building(archetype, origin)
		if bool(result["ok"]):
			placed += 1
			construction_spend += int(result["payload"].get("cost", 0))
			_block_cursor += 1
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

	# --- optional verbs (doc 93 §B, landing in parallel) --------------------

	func repair(sim_id: String) -> Dictionary:
		return _optional("cmd_repair_building", 1, [sim_id], sim_id)

	func buy_block(block_id: String) -> Dictionary:
		return _optional("cmd_buy_block", 1, [block_id], block_id)

	func set_tax_level(level: Variant) -> Dictionary:
		return _optional("cmd_set_tax_level", 1, [level], str(level))

	## Doc 93 §B's headline verb ("THE game"). Not in `sim/` yet, so this path
	## is written blind against the documented `(kind, tile)` shape and is
	## disabled on the first contract mismatch — see `_optional`.
	func place_grid_component(kind: String, tile: Vector2i) -> Dictionary:
		return _optional("cmd_place_grid_component", 2, [kind, tile],
				"%s@%d,%d" % [kind, tile.x, tile.y])

	## Calls an optional verb only when its REQUIRED arity matches what we pass.
	## A verb that lands with a different signature is recorded as
	## `E_VERB_SIGNATURE` and never called again in this run — the harness must
	## degrade, never crash, while doc 93 §B is in flight.
	func _optional(verb: String, arity: int, args: Array, subject: String) -> Dictionary:
		if not has_verb(verb):
			return CommandQueue.fail(&"E_NO_VERB")
		if int(verbs[verb]["required"]) != arity or int(verbs[verb]["args"]) < arity:
			_disabled[verb] = true
			return _log(verb, subject, CommandQueue.fail(&"E_VERB_SIGNATURE"), {})
		var result: Variant = sim.callv(verb, args)
		if not (result is Dictionary) or not (result as Dictionary).has("ok"):
			_disabled[verb] = true
			return _log(verb, subject, CommandQueue.fail(&"E_VERB_CONTRACT"), {})
		return _log(verb, subject, result, {})

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
## it can afford, upgrades whenever the gate is clear, keeps no reserve.
class GreedyGrowth extends Strategy:
	const MAX_ACTIONS_PER_HOUR := 3
	const CATEGORIES: Array[String] = ["residential", "commercial", "industrial"]
	## A greedy agent saves for the densest thing it can eventually buy — but a
	## bounded wait, so a ranking it can never afford cannot freeze it.
	const MAX_SAVE_HOURS := 24

	var _saving_since: int = -1

	func id() -> String:
		return "greedy_growth"

	func describe() -> String:
		return "maximises heads bought per dollar, zero reserve, bounded saving"

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
		return bool(api.place(String(top["archetype"]))["ok"])

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


## Buys the city's bones before its income: service and utility buildings first,
## then infrastructure upgrades, and only spends what is left over a deep
## reserve on revenue floorspace.
class InfrastructureFirst extends Strategy:
	## Deep enough to never miss a payroll, shallow enough that the strategy
	## actually buys something out of the founding $25,000 — the point of this
	## agent is the ORDER it spends in, not hoarding.
	const RESERVE := 8_000
	## Revenue floorspace only out of a much deeper surplus, so the civic ladder
	## always outranks it.
	const REVENUE_RESERVE := 40_000
	const INFRA: Array[String] = ["service", "utility"]
	const REVENUE: Array[String] = ["residential", "commercial", "industrial"]
	## One of each civic archetype per this many residents — the "keep the city
	## covered as it grows" reading of infrastructure-first. Coverage radii are
	## not modelled yet (doc 02 §2.4 lands with Wave 1), so headcount is the
	## only honest proxy a strategy can size against today.
	const CIVIC_PER_POPULATION := 100

	func id() -> String:
		return "infrastructure_first"

	func describe() -> String:
		return "civic/utility first ($8k reserve), revenue only above $40k"

	## Attempts are cheap but not free — a verb that answers `E_FUNDS` every
	## hour would drown the action log.
	const GRID_ATTEMPT_COOLDOWN := 6
	const GRID_ATTEMPT_FLOOR := 20_000

	var _grid_attempt_hour: int = -1000

	func act(api: Api, hour: int) -> void:
		if _repair_something(api):
			return
		if _extend_grid(api, hour):
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
		# Surplus above the reserve buys floorspace, cheapest first, so the
		# civic ladder always outranks it.
		var revenue := _cheapest(api, REVENUE)
		if revenue != "" and api.balance() - api.build_cost(revenue) >= REVENUE_RESERVE:
			api.place(revenue)

	## Doc 93 §B's `cmd_place_grid_component`, used the moment it exists: drop a
	## transformer on the first buildable tile no transformer reaches, which is
	## exactly the `E_UNSERVED` wall this strategy runs into today.
	func _extend_grid(api: Api, hour: int) -> bool:
		if not api.has_verb("cmd_place_grid_component"):
			return false
		if hour - _grid_attempt_hour < GRID_ATTEMPT_COOLDOWN:
			return false
		if api.balance() < RESERVE + GRID_ATTEMPT_FLOOR:
			return false
		_grid_attempt_hour = hour
		var tile := api.unserved_site()
		if tile.x < 0:
			return false
		return bool(api.place_grid_component("transformer", tile)["ok"])

	func _repair_something(api: Api) -> bool:
		if not api.has_verb("cmd_repair_building"):
			return false
		for id in Api._sorted(api.sim.buildings):
			var b: Building = api.sim.buildings[id]
			if b.condition < 0.80 or b.state == &"damaged":
				return bool(api.repair(String(id))["ok"])
		return false

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
## standing before adding more, and add one civic building per city level.
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
	## `cmd_buy_block` does not exist yet (doc 93 §B) — this activates the day it
	## lands and is silent until then.
	const EXPAND_SURPLUS := 80_000
	const EXPAND_COOLDOWN := 24

	var _residential_streak: int = 0
	var _civic_at_level: int = -1
	var _last_expense_per_hour: float = 0.0
	var _expand_hour: int = -1000

	func id() -> String:
		return "balanced"

	func describe() -> String:
		return "2:1 residential:commercial, 1-day expense reserve, upgrade-first"

	func note_expense(expense_per_hour: float) -> void:
		_last_expense_per_hour = expense_per_hour

	func reserve() -> int:
		return maxi(RESERVE_FLOOR,
				int(RESERVE_DAYS_OF_EXPENSE * 24.0 * _last_expense_per_hour))

	func act(api: Api, hour: int) -> void:
		var spare := api.balance() - reserve()
		if spare <= 0:
			return
		# 0. Expand outward when the war chest allows (no-op until the verb lands).
		if _expand(api, hour, spare):
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
		for id in sim.buildings:
			var b: Building = sim.buildings[id]
			if b.state == &"under_construction":
				under_construction += 1
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
		}

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
		for i in range(1, samples.size()):
			var s: Dictionary = samples[i]
			treasury_min = mini(treasury_min, int(s["treasury"]))
			treasury_max = maxi(treasury_max, int(s["treasury"]))
			happiness_min = minf(happiness_min, float(s["happiness"]))
			stability_min = minf(stability_min, float(s["stability"]))
			population_peak = maxi(population_peak, int(s["population"]))
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
		print("%-20s %6s %10s %10s %8s %6s %6s %7s %4s %6s %11s %5s %4s" % [
				"strategy", "seed", "treasury", "peak", "net/gh", "pop", "happy",
				"stab", "lvl", "dark%", "dark_min", "built", "upg"])
		print("-".repeat(118))
		var by_strategy := {}
		for report in runs:
			var s: Dictionary = report["summary"]
			var run_info: Dictionary = report["run"]
			var strategy_id := String(run_info["strategy"])
			if not by_strategy.has(strategy_id):
				by_strategy[strategy_id] = []
			(by_strategy[strategy_id] as Array).append(s)
			print("%-20s %6d %10s %10s %8.1f %6d %6.1f %7.4f %4d %6.2f %11s %5d %4d" % [
					strategy_id, int(run_info["seed"]),
					Fmt.thousands(int(s["treasury_end"])), Fmt.thousands(int(s["treasury_max"])),
					float(s["net_mean_per_hour"]), int(s["population_end"]),
					float(s["happiness_end"]), float(s["stability_end"]),
					int(s["city_level_end"]), 100.0 * float(s["unserved_share"]),
					Fmt.thousands(int(s["blackout_minutes_total"])),
					int(s["placed"]), int(s["upgraded"])])
		print("-".repeat(118))
		for strategy_id in STRATEGY_IDS:
			if not by_strategy.has(strategy_id):
				continue
			var rows: Array = by_strategy[strategy_id]
			print("%-20s %6s %10s %10s %8.1f %6.0f %6.1f %7.4f %4.1f %6.2f %11s %5.1f %4.1f" % [
					("~mean " + strategy_id).substr(0, 20), "-",
					Fmt.thousands(int(_mean(rows, "treasury_end"))),
					Fmt.thousands(int(_mean(rows, "treasury_max"))),
					_mean(rows, "net_mean_per_hour"), _mean(rows, "population_end"),
					_mean(rows, "happiness_end"), _mean(rows, "stability_end"),
					_mean(rows, "city_level_end"), 100.0 * _mean(rows, "unserved_share"),
					Fmt.thousands(int(_mean(rows, "blackout_minutes_total"))),
					_mean(rows, "placed"), _mean(rows, "upgraded")])
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
