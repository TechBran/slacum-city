extends SceneTree
## Doc 92 §67's instrument: **what the utility planner actually bought, and what
## it cost** (Wave 26, report 98 RR-216).
##
## `tools/measure_curriculum.gd` prints the arrival table gate 21 is fitted to;
## it cannot say why a rung landed, because the summary carries counters and not
## purchases. This prints the CAPACITY LEDGER — every water and grid purchase the
## agent made on the arc, with its game-hour, its subject, its verdict and its
## price — plus the pressure zones it was buying for, at the end of the run.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_utility_plan.gd \
##       -- [--days=45] [--seeds=1337,4242,9001] [--strategy=curriculum] [--all]
##
## Same rig `tests/balance_gate_rig.gd` and `measure_curriculum.gd` use, so a
## number printed here is the number gate 21 reads. `--all` prints every logged
## action rather than the capacity ones, for the run where the question is what
## the agent did with its hour instead of what it did with its money.

const Rig := preload("res://tests/balance_gate_rig.gd")

const DEFAULT_DAYS := 45
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const HOURS_PER_DAY := 24

## The verbs `Api._log` records for a capacity purchase. `water` is a placed
## doc-05 component, `water_upgrade` a raised node, `grid_upgrade` a re-rated
## transformer or feeder, `cmd_place_grid_component` a new tap or feeder run.
const CAPACITY_VERBS: Array[String] = [
	"water", "water_upgrade", "grid_upgrade", "cmd_place_grid_component",
]


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS.duplicate()
	var strategy := "curriculum"
	var everything := false
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--strategy="):
			strategy = arg.substr(11)
		elif arg == "--all":
			everything = true
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))

	print("utility plan: strategy=%s, %d game-days, seeds %s"
			% [strategy, days, str(seeds)])
	for seed_value in seeds:
		_one(strategy, int(seed_value), days, everything)
	quit()


func _one(strategy: String, seed_value: int, days: int, everything: bool) -> void:
	var doc: Dictionary = Rig.run(strategy, seed_value, days)
	var summary: Dictionary = doc["summary"]
	print("")
	print("=".repeat(96))
	print("seed %d — goal level %d, city level %d, treasury $%d, population %d"
			% [seed_value, int(summary["goal_level_end"]), int(summary["city_level_end"]),
			int(summary["treasury_end"]), int(summary["population_end"])])
	var arrival := _arrival(doc)
	var levels: Array = arrival.keys()
	levels.sort()
	var row := ""
	for level: Variant in levels:
		row += " L%d@h%d" % [int(level), int(arrival[level])]
	print("  curriculum arrivals:%s" % (row if row != "" else " (none)"))

	var spend := {}
	var counts := {}
	var refusals := {}
	print("  %-6s %-16s %-14s %-22s %s" % ["hour", "verb", "verdict", "subject", "cost"])
	for raw: Variant in (doc["actions"] as Array):
		var entry: Dictionary = raw
		var verb := String(entry.get("verb", ""))
		if not everything and not CAPACITY_VERBS.has(verb):
			continue
		var reason := String(entry.get("reason", ""))
		var ok := bool(entry.get("ok", false))
		var cost := int(entry.get("cost", 0))
		if ok:
			counts[verb] = int(counts.get(verb, 0)) + 1
			spend[verb] = int(spend.get(verb, 0)) + cost
		else:
			var key := "%s/%s" % [verb, reason]
			refusals[key] = int(refusals.get(key, 0)) + 1
		print("  %-6d %-16s %-14s %-22s %s" % [int(entry.get("hour", -1)), verb,
				("OK" if ok else reason), String(entry.get("subject", "")).substr(0, 22),
				("$%d" % cost) if cost > 0 else ""])
	print("  --- bought ---")
	var verbs: Array = counts.keys()
	verbs.sort()
	var total := 0
	for verb: Variant in verbs:
		total += int(spend[verb])
		print("    %-16s n=%-4d $%d" % [String(verb), int(counts[verb]), int(spend[verb])])
	print("    %-16s      $%d" % ["TOTAL", total])
	print("  --- refused ---")
	var keys: Array = refusals.keys()
	keys.sort()
	for key: Variant in keys:
		print("    %-40s %d" % [String(key), int(refusals[key])])

	print("  --- what the upgrade gate still refuses ---")
	for raw_block: Variant in (doc.get("blocked", []) as Array):
		var blocked: Dictionary = raw_block
		print("  %-18s %-10s %-18s $%-9s power_at %-8s %-11s | zone %-10s press %.2f head %.1f"
				% [String(blocked["archetype"]), String(blocked["sim_id"]),
				String(blocked["blocker"]), str(blocked.get("cost", 0)),
				String(blocked.get("power_at", "")), String(blocked.get("power_kind", "")),
				String(blocked.get("water_zone", "")),
				float(blocked.get("water_pressure_at_tile", 0.0)),
				float(blocked.get("water_headroom_m3h", 0.0))])

	print("  --- pressure zones at the end ---")
	print("  %-12s %8s %8s %8s %8s  %s" % ["zone", "supply", "demand", "press", "head",
			"source / treatment / pump rated"])
	for raw: Variant in _zones(doc):
		var z: Dictionary = raw
		print("  %-12s %8.1f %8.1f %8.2f %8.1f  %.1f / %.1f / %.1f" % [String(z["key"]),
				float(z["supply"]), float(z["demand"]), float(z["pressure"]),
				float(z["headroom"]), float(z["source"]), float(z["treatment"]),
				float(z["pump"])])


## First game-hour each curriculum level was earned, off the sample stream —
## `measure_curriculum.gd`'s own reading, so the two tools agree by construction.
func _arrival(doc: Dictionary) -> Dictionary:
	var out := {}
	var highest := 0
	for raw: Variant in (doc["samples"] as Array):
		var sample: Dictionary = raw
		var level := int(sample.get("city_level", 0))
		if level > highest:
			highest = level
			out[level] = int(sample["h"])
	return out


## The rig hands back a document, not a sim, so the zone table is rebuilt from
## the run's own final state by re-reading what the summariser kept. When the
## document carries no zone block the table is empty rather than wrong.
func _zones(doc: Dictionary) -> Array:
	var out: Array = []
	var zones: Variant = doc.get("zones")
	if zones is Array:
		out = zones
	return out
