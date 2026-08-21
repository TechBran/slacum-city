extends SceneTree
## Doc 06 §2.16's beat and doc 03 §2.5's ceiling, on demand.
##
## `data/street.json` ships PLACEHOLDER numbers and the balance agent owns the
## fit; this is the instrument that fit is taken with. It prints, per city and
## per preset:
##
##   * the mean interval between offers, in game-hours — which IS real minutes at
##     1x (`SimHost.GAME_MS_PER_REAL_MS` = 60), so this number is the session beat
##     the player feels;
##   * the mean bounty and the kind mix (the crook share is doc 06 §2.16's
##     coverage hook, read off the city's real `coverage_police` field);
##   * the CEILING — what the layer pays a player who collects every single
##     offer — as dollars per game-hour and as a fraction of doc 03 §2.12's
##     founding net.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_street_yield.gd \
##       -- [--hours=720] [--seeds=1337,4242,9001] [--net=319.0]
##
## **It drives `OpportunitySystem.advance` directly rather than ticking a whole
## city**, at exactly the cadence `CitySim.StreetPhaseSystem` drives it at. That
## is the same code on the same stream off the same candidate index — 0.4 s of
## whole-city advance per game-hour would make a 2,160 game-hour sample a
## fifteen-minute run for a system that reads four scalars — and
## `tests/test_street_opportunities.gd::test_the_phase_adapter_is_wired_to_the_minute`
## is what pins the two together. What it therefore does NOT model is a city that
## CHANGES while it is sampled: coverage, the roster and the road graph are
## whatever the boot left them. For the founding-city question this doc asks,
## that is the right city; for a 45-game-day arc it is not, and the honest tool
## for that one is a `curriculum` run with a tapping agent, which does not exist
## yet (doc 92 §35 ranks it).

const TICKS_PER_HOUR := 240
const MINUTE_TICKS := 4


func _initialize() -> void:
	var hours := 720
	var seeds: Array[int] = [1337, 4242, 9001]
	var founding_net := 319.0
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--hours="):
			hours = int(arg.substr(8))
		elif arg.begins_with("--net="):
			founding_net = float(arg.substr(6))
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(",", false):
				seeds.append(int(part))

	print("street yield: %d game-hours x %d seeds, founding net $%.2f/gh"
			% [hours, seeds.size(), founding_net])
	var offers := 0
	var reward_total := 0
	var by_kind: Dictionary = {}
	var by_kind_reward: Dictionary = {}
	for seed_value in seeds:
		var sim := CitySim.boot_from_files(seed_value)
		if not sim.boot_errors.is_empty():
			printerr("boot: " + str(sim.boot_errors))
			quit(2)
			return
		for i in hours * 60:
			sim.street.advance(float(MINUTE_TICKS * (i + 1)) / float(TICKS_PER_HOUR), true)
			for event in sim.street.drain_events():
				if String(event["type"]) != "opportunity_spawned":
					continue
				var kind := String(event["kind"])
				var reward := int(event["reward"])
				offers += 1
				reward_total += reward
				by_kind[kind] = int(by_kind.get(kind, 0)) + 1
				by_kind_reward[kind] = int(by_kind_reward.get(kind, 0)) + reward
	if offers == 0:
		printerr("no offers: is data/street.json authored?")
		quit(1)
		return

	var gh := float(hours * seeds.size())
	var yield_per_gh := float(reward_total) / gh
	print("")
	print("| metric | value |")
	print("|---|---|")
	print("| offers | %d |" % offers)
	print("| mean interval | **%.3f gh** |" % (gh / float(offers)))
	print("| mean bounty | **$%.2f** |" % (float(reward_total) / float(offers)))
	print("| ceiling (every offer taken) | **$%.2f/gh**, $%.0f/game-day |"
			% [yield_per_gh, 24.0 * yield_per_gh])
	print("| …as a fraction of founding net | **%.0f %%** |"
			% (100.0 * yield_per_gh / maxf(founding_net, 0.000001)))
	print("")
	print("| kind | share | mean bounty |")
	print("|---|---|---|")
	var kinds := by_kind.keys()
	kinds.sort()
	for kind: String in kinds:
		print("| `%s` | %.1f %% | $%.2f |" % [kind,
				100.0 * float(by_kind[kind]) / float(offers),
				float(by_kind_reward[kind]) / float(by_kind[kind])])
	quit(0)
