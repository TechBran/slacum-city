extends SceneTree
## **Where the dark hours actually come from** (Wave 24, doc 92 §63.3).
##
## `tools/measure_dark_share.gd` prints the NUMBER gate 18b asserts.
## This prints the CAUSE, per game-day, because doc 04 gives a building exactly
## three ways to be dark and they are not the same failure:
##
##   1. **unattached** — no transformer's service radius covers its tile
##      (`PowerGrid.unserved_building_ids`);
##   2. **orphaned** — attached to a transformer that is not energized, i.e. one
##      with no live path back to a source (a tap with no parent feeder, or a
##      feeder that has tripped or been shed);
##   3. **starved** — the pool itself is short and doc 04 §2.7 shed the circuit.
##
## Gate 18b's `unserved_share` is the SUM of the three, and a wave that reads
## the sum as "the city has too little capacity" when the answer is (1) will fix
## the wrong thing. Columns: the day's dark share, then the census that explains
## it.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/probe_dark.gd \
##       -- [--days=50] [--seed=1337] [--strategy=balanced] [--every=5]
##
## Drives `BalanceGateRig`'s own loop so a row here is the gate's own city.
## It owns no constant (constitution §3).

const Playtest := preload("res://tools/playtest.gd")

const HOURS_PER_DAY := 24


func _initialize() -> void:
	var days := 50
	var seed_value := 1337
	var strategy_id := "balanced"
	var every := 5
	for raw: Variant in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--strategy="):
			strategy_id = arg.substr(11)
		elif arg.begins_with("--every="):
			every = maxi(1, int(arg.substr(8)))

	var sim := CitySim.boot_from_files(seed_value)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	var events: Dictionary = {}
	sim.bus.drain()

	print("probe_dark: strategy=%s seed=%d days=%d" % [strategy_id, seed_value, days])
	print("| day | dark % | unattached | orphaned | shed feeders | failed comps | "
			+ "buildings | taps | unparented taps | feeders | subs | supply kW | "
			+ "demand kW | tx crit | treasury |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")

	var dark_day := 0.0
	var metered_day := 0.0
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, 0.0)
		if strategy is Playtest.Balanced:
			(strategy as Playtest.Balanced).note_expense(float(sample["expenses"]))
		# The same reading `Playtest.Runner._blackout_minutes` takes, kept per day.
		for id: Variant in sim.buildings:
			var b: Building = sim.buildings[id]
			if b.archetype == &"substation":
				continue
			dark_day += (1.0 - sim.grid.power_availability_hour(String(id))) * 60.0
			metered_day += 60.0
		if (h + 1) % (HOURS_PER_DAY * every) != 0:
			continue
		print(_row(sim, (h + 1) / HOURS_PER_DAY, dark_day, metered_day))
		dark_day = 0.0
		metered_day = 0.0
	quit(0)


func _row(sim: CitySim, day: int, dark: float, metered: float) -> String:
	var caps := sim.grid.capacity_summary()
	var unattached := sim.grid.unserved_building_ids().size()
	var orphaned := 0
	for id: Variant in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.archetype == &"substation":
			continue
		var tap := sim.grid.attachment_of(String(id))
		if tap != "" and not sim.grid.is_energized(tap):
			orphaned += 1
	var unparented := 0
	for raw: Variant in sim.grid.component_ids_of_kind(&"transformer"):
		if String(sim.grid.component(String(raw)).get("parent", "")) == "":
			unparented += 1
	var failed := 0
	for raw: Variant in sim.grid.component_ids():
		if String(sim.grid.component(String(raw)).get("state", "OK")) != "OK":
			failed += 1
	return ("| %d | **%.2f** | %d | %d | %d | %d | %d | %d | %d | %d | %d | "
			+ "%.0f | %.0f | %d | $%d |") % [
			day, 100.0 * dark / maxf(1.0, metered), unattached, orphaned,
			int(caps["shed_feeders"]), failed, sim.buildings.size(),
			int(caps["transformers"]), unparented, int(caps["feeders"]),
			sim.grid.component_ids_of_kind(&"substation").size(),
			float(caps["supply_kw"]), float(caps["demand_kw"]),
			int(caps["transformers_critical"]), sim.treasury.balance]
