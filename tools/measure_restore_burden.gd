extends SceneTree
## What it costs to bring a city's RUINS back — doc 92 §54's derivation, as an
## instrument rather than a hand measurement.
##
## The 2026-09-02 playtest said one thing about destroyed buildings: *"I have
## many buildings that are destroyed that I can't actually fix even if I upgrade
## power"*, and *"the price should be MODEST"*. Both halves are numbers before
## they are rulings, and this is the instrument that takes them. It boots the
## real `CitySim`, drives a `tools/playtest.gd` strategy through the real command
## layer on the coarse step (the same rig every doc 92 table is measured on), and
## reports:
##
##   * **how many ruins stand at once** — the peak simultaneous `destroyed`
##     count over the arc, when it peaked, and the roster (archetype × level ×
##     tax class) standing at the end;
##   * **what a restore costs at each candidate fraction**, per ruin and for the
##     whole standing set, as a multiple of the day's net at that point;
##   * **the day's net by city level**, sampled off the same run, so §54's
##     "fraction of a day's net at L2/L3/L4" is read rather than assumed;
##   * **the neglect-arbitrage table** — the deepest repair a player would ever
##     sanely buy (doc 02 §2.6's auto-damage line, `damage_fraction = 0.65`)
##     against the restore price, per archetype and level. A restore CHEAPER than
##     that repair would pay the player to let a building fall down, which is the
##     one thing a restore price must never do. `owner_maintained` stock is
##     marked, because doc 02 §2.6a means the city can never buy its repair at
##     all and there is nothing for a cheap restore to undercut.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_restore_burden.gd \
##       -- [--days=45] [--seeds=1337] [--strategies=disaster_neglect,do_nothing]
##          [--fractions=0.12,0.20,0.30,0.60] [--city=starter|bench]
##
## A MEASURING instrument (constitution §3): it owns no balance constant of its
## own — the candidate fractions arrive on the command line and the shipped one
## is read out of `data/economy.json` — and nothing in `sim/` imports it.

const Playtest := preload("res://tools/playtest.gd")

const STARTER_CITY := "res://data/starter_city.json"
const BENCH_CITY := "res://tests/fixtures/bench_city.json"
const HOURS_PER_DAY := 24
## Doc 02 §2.6's auto-damage line. A building below it is `damaged` and heading
## for the structural-failure roll; it is the deepest repair a player still
## buying repairs would ever face, so it is the floor a restore price is checked
## against.
const AUTO_DAMAGE_LINE := 0.35
## The archetype × level cells the arbitrage table prints. One private ladder,
## one civic ladder and one utility ladder — enough to show the shape without
## printing the whole roster.
const ARBITRAGE_TYPES: Array[String] = ["house", "store", "office", "highrise_res",
		"fire_station", "power_plant_gas"]


func _initialize() -> void:
	var days := 45
	var seeds: Array[int] = [1337]
	var strategies: Array[String] = ["disaster_neglect", "do_nothing"]
	var fractions: Array[float] = [0.12, 0.20, 0.30, 0.60]
	var city := "starter"
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.split("=", true, 1)
		var key := String(split[0])
		var value := String(split[1]) if split.size() > 1 else ""
		match key:
			"--days": days = int(value)
			"--city": city = value
			"--seeds":
				seeds = [] as Array[int]
				for part in value.split(","):
					seeds.append(int(part))
			"--strategies":
				strategies = [] as Array[String]
				for part in value.split(","):
					strategies.append(String(part))
			"--fractions":
				fractions = [] as Array[float]
				for part in value.split(","):
					fractions.append(float(part))
			_:
				printerr("unknown option: ", arg)
				quit(2)
				return

	print("restore burden · city=%s · %d game-days · seeds %s · strategies %s"
			% [city, days, str(seeds), str(strategies)])
	print("candidate fractions of capital_value(L): %s" % str(fractions))
	print("")
	for strategy_id in strategies:
		for seed_value in seeds:
			_one(city, strategy_id, int(seed_value), days, fractions)
	_arbitrage(fractions)
	quit(0)


## `tools/measure_repair_burden.gd`'s boot, verbatim in shape: the starter city
## through the published helper, the benchmark fixture through the same six
## inputs so the two instruments cannot boot different cities.
func _boot(city: String, seed_value: int) -> CitySim:
	if city == "starter":
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(BENCH_CITY),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	if not sim.boot_errors.is_empty():
		printerr("measure_restore_burden: %d boot error(s)" % sim.boot_errors.size())
		for message in sim.boot_errors:
			printerr("  " + String(message))
	return sim


## One arc, hour by hour, on the coarse path the gates use.
func _one(city: String, strategy_id: String, seed_value: int, days: int,
		fractions: Array[float]) -> void:
	var sim := _boot(city, seed_value)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()

	# net per game-hour, bucketed by the city level it was earned at.
	var net_by_level: Dictionary = {}   # int level -> [sum, count]
	var peak_destroyed := 0
	var peak_hour := -1
	var destroyed_ever: Dictionary = {}  # sim_id -> true
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		var settled: Dictionary = Playtest.Runner._drain(sim, {})
		var level := sim.progression.city_level
		var bucket: Array = net_by_level.get(level, [0.0, 0])
		bucket[0] = float(bucket[0]) + float(settled.get("net", 0.0))
		bucket[1] = int(bucket[1]) + 1
		net_by_level[level] = bucket
		var standing := 0
		for id: Variant in sim.buildings:
			if (sim.buildings[id] as Building).state == &"destroyed":
				standing += 1
				destroyed_ever[String(id)] = true
		if standing > peak_destroyed:
			peak_destroyed = standing
			peak_hour = h

	print("== %s · seed %d · %s · %d game-days" % [strategy_id, seed_value, city, days])
	print("| city level | mean net $/gh | net $/game-day | game-hours at this level |")
	print("|---|---|---|---|")
	for level: Variant in _sorted_keys(net_by_level):
		var bucket: Array = net_by_level[level]
		var mean := float(bucket[0]) / maxf(1.0, float(bucket[1]))
		print("| %d | %.2f | %.0f | %d |" % [int(level), mean, mean * HOURS_PER_DAY,
				int(bucket[1])])

	var ruins := _ruins(sim)
	print("  peak simultaneous ruins %d (game-hour %d) · distinct buildings destroyed over the arc %d"
			% [peak_destroyed, peak_hour, destroyed_ever.size()])
	print("  ruins standing at the end: %d" % ruins.size())
	if ruins.is_empty():
		print("")
		return

	var end_level := sim.progression.city_level
	var end_bucket: Array = net_by_level.get(end_level, [0.0, 0])
	var day_net := float(end_bucket[0]) / maxf(1.0, float(end_bucket[1])) * HOURS_PER_DAY
	print("  day's net at the end (city level %d): $%.0f" % [end_level, day_net])
	var header := "| ruin | archetype | L | owner-maintained | capital $ "
	for f in fractions:
		header += "| restore @%.2f " % f
	print(header + "|")
	var rule := "|---|---|---|---|---|"
	for f in fractions:
		rule += "---|"
	print(rule)
	var totals: Array[int] = []
	for f in fractions:
		totals.append(0)
	for ruin: Dictionary in ruins:
		var row := "| %s | %s | %d | %s | %d " % [str(ruin["sim_id"]), str(ruin["type"]),
				int(ruin["level"]), "yes" if bool(ruin["owner"]) else "no",
				int(ruin["capital"])]
		for i in fractions.size():
			var price := CostCurves.round_half_up(float(ruin["capital"]) * fractions[i])
			totals[i] = totals[i] + price
			row += "| %d " % price
		print(row + "|")
	var total_row := "| **ALL %d** | — | — | — | — " % ruins.size()
	var share_row := "| share of ONE day's net | — | — | — | — "
	for i in fractions.size():
		total_row += "| %d " % totals[i]
		share_row += "| %.2f× " % (float(totals[i]) / maxf(1.0, day_net))
	print(total_row + "|")
	print(share_row + "|")
	print("")


## Every ruin standing right now, with what a restore would be priced against.
func _ruins(sim: CitySim) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: Variant in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state != &"destroyed":
			continue
		var type := String(b.archetype)
		var level := maxi(b.level_at_destruction, 1)
		out.append({
			"sim_id": String(id),
			"type": type,
			"level": level,
			"owner": sim.catalog.owner_maintained(type),
			"capital": sim.econ_curves.capital_value(type, level),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["sim_id"]) < String(b["sim_id"]))
	return out


## The one table a restore price must be read against: is letting a building
## fall down CHEAPER than repairing it? A restore below the auto-damage-line
## repair pays for neglect, and no fraction that fails this row may ship for
## stock the city actually repairs.
func _arbitrage(fractions: Array[float]) -> void:
	var curves := CostCurves.load_from_files()
	var catalog := BuildingCatalog.load_from_files()
	print("== neglect arbitrage · repair at doc 02's auto-damage line (damage %.2f) vs restore"
			% (1.0 - AUTO_DAMAGE_LINE))
	var header := "| archetype | L | owner-maintained | capital $ | repair@0.35 $ "
	for f in fractions:
		header += "| restore @%.2f " % f
	print(header + "|")
	var rule := "|---|---|---|---|---|"
	for f in fractions:
		rule += "---|"
	print(rule)
	for type in ARBITRAGE_TYPES:
		var owner := catalog.owner_maintained(type)
		for level in range(1, catalog.max_level_of(type) + 1):
			var capital := curves.capital_value(type, level)
			var repair := curves.repair_cost(capital, 1.0 - AUTO_DAMAGE_LINE, 1.0)
			var row := "| %s | %d | %s | %d | %d " % [type, level,
					"yes" if owner else "no", capital, repair]
			for f in fractions:
				row += "| %d " % CostCurves.round_half_up(float(capital) * f)
			print(row + "|")
	print("")


func _sorted_keys(d: Dictionary) -> Array:
	var keys: Array = d.keys()
	keys.sort()
	return keys
