extends SceneTree
## The neglect-fatal table — doc 92 §29.3's insolvency measurement, as an
## instrument instead of a hand run.
##
## **The measure is insolvency**: the first game-day on which a `do_nothing`
## city's treasury closes below zero. It is chosen over "buildings destroyed"
## because the roster does not shrink — a destroyed building keeps its record —
## so a count of destroyed buildings is a STATE, while the day the money runs out
## is an EVENT, and it is the one the player meets (`credit_line_engaged`, then
## doc 03 §2.10 layer 4's −$20,000 floor).
##
## It drives `CitySim` directly rather than `tools/playtest.gd`'s `Api`, because
## `do_nothing` issues no commands: the control curve is the city left alone, and
## the shortest honest way to measure it is to advance it. Same coarse step the
## gates and `tests/balance_matrix.gd` use (`advance_coarse_hours(1, false)` —
## online, not a catch-up session).
##
## **It stops at insolvency**, and that is a hazard rule rather than thrift. Doc
## 92 §29.5(b): a neglected city eventually cascades, and past the cascade a run
## does not finish — measured on `crisis`, from game-day 104 the open incident
## count multiplies by ~2.5–2.9 per game-hour with no ceiling. `--max-days`
## bounds every run and `--stop-at-insolvency` (the default) leaves before the
## state that produces it.
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/measure_insolvency.gd -- [options]
##
##   --seeds=a,b,c   RNG seeds, one run each         (default 1337,4242,9001)
##   --presets=a,b   subset of doc 03 §2.9's four    (default all)
##   --max-days=N    horizon ceiling per run         (default 200)
##   --run-on        do NOT stop at insolvency — run every horizon to the end.
##                   Read §29.5(b) before using it on a harsh preset.
const DEFAULT_SEEDS: Array[int] = [1337, 4242, 9001]
const DEFAULT_MAX_DAYS := 200
const HOURS_PER_DAY := 24


func _initialize() -> void:
	var seeds: Array[int] = DEFAULT_SEEDS.duplicate()
	var presets: Array[String] = Difficulty.PRESETS.duplicate()
	var max_days := DEFAULT_MAX_DAYS
	var stop_at_insolvency := true
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		var key := arg if split < 0 else arg.substr(0, split)
		var value := "" if split < 0 else arg.substr(split + 1)
		match key:
			"--seeds", "seeds":
				seeds = [] as Array[int]
				for part in value.split(",", false):
					seeds.append(int(part))
			"--presets", "presets":
				presets = []
				for part in value.split(",", false):
					presets.append(String(part))
			"--max-days", "max-days", "max_days":
				max_days = maxi(1, int(value))
			"--run-on", "run-on", "run_on":
				stop_at_insolvency = false
	for preset in presets:
		if not Difficulty.is_preset(preset):
			printerr("measure_insolvency: unknown preset " + preset)
			quit(2)
			return
	if seeds.is_empty():
		printerr("measure_insolvency: --seeds needs at least one seed")
		quit(2)
		return

	print("neglect-fatal table · do_nothing · coarse path · ceiling %d game-days"
			% max_days)
	print("")
	var header: PackedStringArray = ["| preset "]
	for seed_value in seeds:
		header.append("| seed %d " % seed_value)
	print("".join(header) + "| mean | peak treasury (game-day) | peak open inc | wall s |")
	print("|---".repeat(seeds.size() + 5) + "|")
	for preset in presets:
		var days: PackedStringArray = []
		var total := 0
		var counted := 0
		var peak_treasury := 0
		var peak_day := 0
		var peak_open := 0
		var wall := 0.0
		for seed_value in seeds:
			var t0 := Time.get_ticks_msec()
			var row := _run(preset, seed_value, max_days, stop_at_insolvency)
			wall += float(Time.get_ticks_msec() - t0) / 1000.0
			var day := int(row["day"])
			days.append("| **%s** " % ("—" if day < 0 else str(day)))
			if day > 0:
				total += day
				counted += 1
			if int(row["peak_treasury"]) > peak_treasury:
				peak_treasury = int(row["peak_treasury"])
				peak_day = int(row["peak_day"])
			peak_open = maxi(peak_open, int(row["peak_open"]))
		var mean := "—" if counted == 0 else "%.1f" % (float(total) / float(counted))
		print("| `%s` %s| %s | $%d (day %d) | %d | %.1f |"
				% [preset, "".join(days), mean, peak_treasury, peak_day, peak_open,
				wall])
	quit(0)


## One city, left alone. Returns the game-day the treasury first closes negative
## (−1 if it never does inside the ceiling), the peak balance and its day, and
## the peak simultaneous open-incident count — §29.5(b)'s tripwire.
func _run(preset: String, seed_value: int, max_days: int,
		stop_at_insolvency: bool) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, preset)
	var day := -1
	var peak_treasury := sim.treasury.balance
	var peak_day := 0
	var peak_open := 0
	for hour in max_days * HOURS_PER_DAY:
		sim.advance_coarse_hours(1, false)
		sim.bus.drain()
		var open_count := sim.incidents.active_count() if sim.incidents != null else 0
		peak_open = maxi(peak_open, open_count)
		if sim.treasury.balance > peak_treasury:
			peak_treasury = sim.treasury.balance
			peak_day = (hour + 1) / HOURS_PER_DAY
		if (hour + 1) % HOURS_PER_DAY != 0:
			continue
		var closing_day := (hour + 1) / HOURS_PER_DAY
		if day < 0 and sim.treasury.balance < 0:
			day = closing_day
			if stop_at_insolvency:
				break
	return {"day": day, "peak_treasury": peak_treasury, "peak_day": peak_day,
			"peak_open": peak_open}
