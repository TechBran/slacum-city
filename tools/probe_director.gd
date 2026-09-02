extends SceneTree
## PA-04 probe: a 60-game-day online balanced run, coarse step, and what the
## Disaster Director had to show for it. Runs unchanged on the fork and on the
## fix, so the two numbers are comparable.

const Playtest := preload("res://tools/playtest.gd")


func _initialize() -> void:
	var seed_value := 4242
	var days := 60
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--days="):
			days = int(arg.substr(7))
	var sim := CitySim.boot_from_files(seed_value)
	var strategy := Playtest.Factory.make("balanced")
	var api := Playtest.Api.new(sim)
	var events: Dictionary = {}
	sim.bus.drain()
	var active_by_day: Array = []
	for h in days * 24:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, 0.0)
		strategy.note_expense(float(sample["expenses"]))
		if (h + 1) % 24 == 0:
			active_by_day.append(sim.director.active_events.size())
	var max_hold := 0
	for row in sim.director.history:
		max_hold = maxi(max_hold, int(row["end_min"]) - int(row["start_min"]))
	var last_start := -1
	for id in sim.director.last_event_start_min:
		last_start = maxi(last_start, int(sim.director.last_event_start_min[id]))
	print("probe_director seed=%d days=%d" % [seed_value, days])
	print("  director_event_started : %d" % int(events.get("director_event_started", 0)))
	print("  director_event_ended   : %d" % int(events.get("director_event_ended", 0)))
	print("  weather_warning        : %d" % int(events.get("weather_warning", 0)))
	print("  history(resolved)      : %d" % sim.director.history.size())
	print("  active_end             : %d" % sim.director.active_events.size())
	print("  max_hold_min           : %d" % max_hold)
	print("  last_start_min         : %d  (game-day %.1f)"
			% [last_start, float(last_start) / 1440.0])
	print("  tp_pool                : %.1f" % sim.director.tp_pool)
	print("  active_by_day          : %s" % str(active_by_day))
	var kinds: Dictionary = {}
	for row in sim.director.history:
		kinds[String(row["type"])] = int(kinds.get(String(row["type"]), 0)) + 1
	print("  resolved_kinds         : %s" % str(kinds))
	quit(0)
