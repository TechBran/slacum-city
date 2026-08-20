extends SceneTree
## Inside `roads_congestion` — where the fine tick's largest term actually goes,
## and whether any of its edges could be SKIPPED (doc 10 §9.3 C-3, doc 91 D-15).
##
## `tools/profile_sim.gd` reports `roads_congestion` as ONE row and amortizes it
## across the four SimTicks of the game-minute, because the system declares
## `EVERY_TICK` and picks its pass from `tick_index % 4`. That row says the
## system is 30 % of the fine tick and nothing about which of its three passes
## the 30 % is in. This tool boots the same real `CitySim`, drives the same real
## scheduler, and splits the row by the tick of the minute that carried it —
## using the scheduler's own opt-in timing hook, so nothing is perturbed:
##
##   tick 0 of the minute  `RoadNetwork.full_pass`   (congestion + the c_day sample)
##   tick 1                `TrafficSnapshot.rebuild`
##   tick 2                `TrafficFeed.rebalance`
##   tick 3                nothing
##
## Then it times, separately and side-effect-free, the two whole-graph sweeps
## hiding inside the first of those — `CongestionModel.mean_congestion` (a
## SECOND O(E) walk after the pass has already touched every edge) and
## `RoadGraph.dark_signal_counts_by_edge` (an O(nodes) walk taken every pass
## whether or not any signal is dark).
##
## And it answers the dirty set's own question, which is not a timing question:
## **how many edges MOVE on an ordinary pass?** A dirty set may skip an edge only
## where the full sweep would have left it unchanged. `hour` reaches every edge
## through `D_tod`, and the smoother `c ← c + (c_raw − c)·α` never lands on its
## target, so the honest answer is a census rather than an argument.
##
## MEASURING instrument (constitution §3): owns no constant, boots the shipped
## sim, and nothing in `sim/` or `game/` imports it.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_congestion.gd -- [options]
##
##   --city=PATH      city file (default res://tests/fixtures/bench_city.json)
##   --seed=N         RNG seed                                  (default 1337)
##   --warm-hours=F   game-hours advanced before measuring      (default 0.5)
##   --minutes=N      game-minutes measured                     (default 60)
##   --probes=N       repeats of each side-effect-free micro-timing (default 200)
##   --quiet          table only

const STARTER_CITY := "res://data/starter_city.json"
const BENCH_CITY := "res://tests/fixtures/bench_city.json"

var _opts: Dictionary = {}
## `(system_id, tick-of-minute)` -> usec, filled by the scheduler hook.
var _usec: Dictionary = {}
var _calls: Dictionary = {}
var _stack: Array[int] = []
var _keys: Array[String] = []
var _tick_of_minute := 0
var _clock: GameClock


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if not String(_opts["error"]).is_empty():
		printerr("profile_congestion: " + String(_opts["error"]))
		quit(2)
		return
	var sim := _boot(int(_opts["seed"]))
	sim.advance_hours(float(_opts["warm_hours"]))
	var roads: RoadNetwork = sim.roads
	var graph: RoadGraph = roads.graph
	var edges := graph.edge_ids_ref().size()
	var nodes := graph.node_ids_ref().size()

	var minutes := int(_opts["minutes"])
	_clock = sim.clock
	sim.scheduler.profile_enter = _enter
	sim.scheduler.profile_exit = _exit
	sim.scheduler.profiling = true
	sim.scheduler.advance_fine_n(minutes * GameClock.TICKS_PER_MINUTE)
	sim.scheduler.profiling = false

	var probes := int(_opts["probes"])
	var mean_ms := _probe(func() -> void: roads.congestion.mean_congestion(), probes)
	var dark_ms := _probe(func() -> void: graph.dark_signal_counts_by_edge(), probes)

	if not bool(_opts["quiet"]):
		print("")
	print("=== roads_congestion — %s, %d edges, %d nodes, %d game-minutes ==="
			% [String(_opts["city"]).get_file(), edges, nodes, minutes])
	print("  pass                                    ms/game-minute   calls")
	print("  ------------------------------------------------------------------")
	_row("tick 0  RoadNetwork.full_pass", 0, minutes)
	_row("tick 1  TrafficSnapshot.rebuild", 1, minutes)
	_row("tick 2  TrafficFeed.rebalance", 2, minutes)
	_row("tick 3  (idle)", 3, minutes)
	print("  ------------------------------------------------------------------")
	print("  %-38s  %13.4f" % ["SimTick mean (what profile_sim prints)",
			_system_ms(&"roads_congestion")
			/ float(maxi(minutes * GameClock.TICKS_PER_MINUTE, 1))])
	print("")
	print("  whole-graph sweeps inside tick 0, timed on their own:")
	print("  %-38s  %13.4f" % ["CongestionModel.mean_congestion", mean_ms])
	print("  %-38s  %13.4f" % ["RoadGraph.dark_signal_counts_by_edge", dark_ms])
	print("")
	print("  THE DIRTY SET'S CENSUS")
	print("  edges whose c_e moved on the last full pass: %d of %d"
			% [roads.congestion.last_moved, edges])
	print("  A dirty set may skip an edge only where the full sweep would leave")
	print("  it unchanged. `hour` reaches every edge through D_tod and the")
	print("  smoother never lands on its target, so this row is the skippable set.")
	quit(0)


func _row(label: String, tick: int, minutes: int) -> void:
	var key := "roads_congestion@%d" % tick
	var usec := int(_usec.get(key, 0))
	print("  %-38s  %13.4f   %d"
			% [label, float(usec) * 0.001 / float(maxi(minutes, 1)),
			int(_calls.get(key, 0))])


## One system's whole cost across every tick of the minute.
func _system_ms(id: StringName) -> float:
	var total := 0
	var prefix := String(id) + "@"
	for key: String in _usec:
		if key.begins_with(prefix):
			total += int(_usec[key])
	return float(total) * 0.001


## `repeats` calls of a SIDE-EFFECT-FREE query, wall-clocked. Both probes below
## only read: `mean_congestion` sums a field, `dark_signal_counts_by_edge`
## builds a fresh dictionary. Neither writes the graph, so the sim is where the
## scheduler left it when the table is printed.
static func _probe(what: Callable, repeats: int) -> float:
	var t0 := Time.get_ticks_usec()
	for i in repeats:
		what.call()
	return float(Time.get_ticks_usec() - t0) * 0.001 / float(maxi(repeats, 1))


# ------------------------------------------------------- the scheduler hook

func _enter(id: StringName) -> void:
	if id == &"@context":
		_tick_of_minute = _clock.tick_index % GameClock.TICKS_PER_MINUTE
	var key := "%s@%d" % [String(id), _tick_of_minute]
	_keys.append(key)
	_stack.append(Time.get_ticks_usec())


func _exit(_id: StringName) -> void:
	if _stack.is_empty():
		return
	var started: int = _stack.pop_back()
	var usec := Time.get_ticks_usec() - started
	var key: String = _keys.pop_back()
	_usec[key] = int(_usec.get(key, 0)) + usec
	_calls[key] = int(_calls.get(key, 0)) + 1


# --------------------------------------------------------------------- boot

## The same five data files `tools/profile_sim.gd` boots, with the city swapped.
func _boot(seed_value: int) -> CitySim:
	var city := String(_opts["city"])
	if city == STARTER_CITY:
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	for message in sim.boot_errors:
		printerr("  boot: " + String(message))
	return sim


func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {
		"city": BENCH_CITY, "seed": 1337, "warm_hours": 0.5,
		"minutes": 60, "probes": 200, "quiet": false, "error": "",
	}
	for arg in argv:
		if arg.begins_with("--city="):
			opts["city"] = arg.substr(7)
		elif arg.begins_with("--seed="):
			opts["seed"] = int(arg.substr(7))
		elif arg.begins_with("--warm-hours="):
			opts["warm_hours"] = maxf(0.0, float(arg.substr(13)))
		elif arg.begins_with("--minutes="):
			opts["minutes"] = maxi(1, int(arg.substr(10)))
		elif arg.begins_with("--probes="):
			opts["probes"] = maxi(1, int(arg.substr(9)))
		elif arg == "--quiet":
			opts["quiet"] = true
		else:
			opts["error"] = "unknown option " + arg
	return opts
