extends SceneTree
## The money pass's feel metric, on demand (doc 92 §36).
##
## Doc 03's ledger says what the city earns per game-hour. `data/time.json` says
## `real_seconds_per_game_minute = 1.0`, so **one game-hour is one real minute at
## 1x** — which means the ledger's $/gh column IS the player's $/real-minute and
## no conversion is needed anywhere in this file. That identity is the whole
## reason this instrument can answer "it feels slow" with a number.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_money_pass.gd \
##       -- [--days=21] [--seeds=1337,4242,9001] [--strategy=curriculum]
##
## Three columns, per curriculum level:
##
##   * **net $/gh** — the mean settled net over the level's window. The purse.
##   * **city services $/gh** — the mean dispatch/street payout over the same
##     window, and its share of net. Zero before this wave: doc 06 credited
##     `reward_base` straight to the treasury and no ledger line ever named it.
##   * **BROKE game-minutes** — game-hours in which the treasury could not buy
##     the cheapest thing on the build sheet (a level-1 house, $1,200). This is
##     the dead time the player reported: not "I am poor", but *there is nothing
##     I can press*. Counted per level window, printed as a share of it.
##
## Same rig `tests/balance_gate_rig.gd` uses, so a number printed here is a
## number a gate can read.

const DEFAULT_DAYS := 21
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const HOURS_PER_DAY := 24
## Doc 03 §2.13(a): the cheapest row on the build sheet. A treasury below this
## can buy NOTHING, which is the definition of a broke game-minute.
const CHEAPEST_BUILD := 1200


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS.duplicate()
	var strategy := "curriculum"
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--strategy="):
			strategy = arg.substr(11)
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(","):
				seeds.append(int(part))

	print("money pass: strategy=%s, %d game-days, 1 game-hour = 1 real minute at 1x"
			% [strategy, days])
	for seed_value in seeds:
		_one(strategy, int(seed_value), days)
	quit(0)


func _one(strategy: String, seed_value: int, days: int) -> void:
	var run := BalanceGateRig.run(strategy, seed_value, days)
	var samples: Array = run["samples"]
	var arrivals := _first_hour_at(run)
	var funds_hours := _e_funds_hours(run)

	print("")
	print("seed %d  —  %s" % [seed_value, strategy])
	# A plain `print`, not a format call, so the percent sign is written once.
	print("| level | arrives gh | window gh | net $/gh | services $/gh | share | broke gm | broke % |")
	var top := GoalSystem.top_level()
	for level in range(1, top + 1):
		if not arrivals.has(level):
			continue
		var from := int(arrivals.get(level - 1, 0))
		var to := int(arrivals[level])
		if to <= from:
			continue
		var net := 0.0
		var services := 0.0
		var broke := 0
		for i in range(from + 1, mini(to + 1, samples.size())):
			var sample: Dictionary = samples[i]
			net += float(sample.get("net", 0.0))
			services += float(sample.get("city_services", 0.0))
			if int(sample.get("treasury", 0)) < CHEAPEST_BUILD:
				broke += 1
		var span := float(to - from)
		print("| %5d | %10d | %9d | %8.1f | %13.1f | %4.1f%% | %8d | %6.1f%% |"
				% [level, to, to - from, net / span, services / span,
				100.0 * services / maxf(1.0, net), broke, 100.0 * float(broke) / span])

	var total_services := 0.0
	var total_net := 0.0
	var total_broke := 0
	for i in range(1, samples.size()):
		var sample: Dictionary = samples[i]
		total_net += float(sample.get("net", 0.0))
		total_services += float(sample.get("city_services", 0.0))
		if int(sample.get("treasury", 0)) < CHEAPEST_BUILD:
			total_broke += 1
	var hours := float(samples.size() - 1)
	print("whole run: net $%.1f/gh, city services $%.1f/gh (%.2f%% of net), "
			% [total_net / hours, total_services / hours,
			100.0 * total_services / maxf(1.0, total_net)]
			+ "broke %d/%d game-minutes (%.1f%%), E_FUNDS in %d game-hours"
			% [total_broke, int(hours), 100.0 * float(total_broke) / hours, funds_hours])
	print("  treasury_end %s  population_end %s  goal_level_end %s  state_hash %s"
			% [str((run["summary"] as Dictionary).get("treasury_end", "—")),
			str((run["summary"] as Dictionary).get("population_end", "—")),
			str((run["summary"] as Dictionary).get("goal_level_end", "—")),
			str(run.get("state_hash", ""))])


func _first_hour_at(run: Dictionary) -> Dictionary:
	var out: Dictionary = {0: 0}
	for entry: Variant in (run["samples"] as Array):
		var sample: Dictionary = entry
		var level := int(sample.get("goal_level", 0))
		if level > 0 and not out.has(level):
			out[level] = int(sample["h"])
	return out


## Distinct game-hours in which the agent asked for something and was told it
## could not afford it. The agent's own intent, not a guess at the player's.
func _e_funds_hours(run: Dictionary) -> int:
	var hours := {}
	for entry: Variant in (run["actions"] as Array):
		var action: Dictionary = entry
		if String(action.get("reason", "")) == "E_FUNDS":
			hours[int(action.get("hour", -1))] = true
	return hours.size()
