extends SceneTree
## The founding ledger, preset by preset — doc 92 §29.2's table, as an
## instrument instead of a hand measurement.
##
## §29.2 published the four founding rows and the eight-line expense breakdown
## that made §29.5's finding legible, and it published them from an ad-hoc run.
## Doc 92 §32 re-takes the same table after the `E_roads_repair` ruling, so the
## measurement gets a file: boot a `do_nothing` city on each preset, advance
## `--hours` game-hours, and print the mean of every line over them. At the
## default `--hours=1` that is exactly §29.2's founding hour; at `--hours=504` it
## is the same ledger over doc 92's 21-game-day horizon, which is what the
## `M_rev` scope ruling needed (doc 93 §N2).
##
## Like `tools/playtest.gd` and `tools/profile_sim.gd` this is a MEASURING
## instrument — it boots the real `CitySim`, owns no constant of its own, and is
## never imported by `sim/` (constitution §3).
##
## Usage:
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/measure_founding_ledger.gd -- [options]
##
##   --seed=N        RNG seed                                  (default 1337)
##   --hours=N       game-hours to settle; every line is the MEAN over them
##                   (default 1 — §29.2's founding snapshot)
##   --presets=a,b   subset of doc 03 §2.9's four              (default all)
##   --mode=coarse|fine   which advance path settles the hour  (default coarse)
##
## `--mode` defaults to `coarse` because that is the path §29.2 was taken on and
## the path `tests/balance_matrix.gd` drives, and this tool has to reproduce that
## table before it is allowed to publish a new one. The fine path is a legal
## measurement of the same hour and lands within doc 01 §9 item 4's ±5 % band
## (standard: 838.99 gross vs 841.22, +335.19 net vs +337.05) — the founding
## hour is stochastic in `fines` and in the water tariff, and nowhere else.
##
## The revenue split it prints (`tax` vs everything else) is the one §29.2 had to
## solve for algebraically to find the `M_rev` semantics finding: it is read
## straight off the snapshot here.
const DEFAULT_SEED := 1337
const DEFAULT_HOURS := 1

## The eight recurring lines of doc 03 §2.4, in the doc's own order, plus the
## debt line that carries its own difficulty term.
const EXPENSE_LINES: Array[String] = ["building_maint", "departments", "fleet",
		"vehicle_fuel", "grid", "generation_fuel", "water", "roads_repair", "debt"]
const REVENUE_LINES: Array[String] = ["tax", "power_tariff", "water_tariff", "fines"]


func _initialize() -> void:
	var seed_value := DEFAULT_SEED
	var hours := DEFAULT_HOURS
	var presets: Array[String] = Difficulty.PRESETS.duplicate()
	var mode := "coarse"
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		if split < 0:
			continue
		var key := arg.substr(0, split)
		var value := arg.substr(split + 1)
		match key:
			"--seed", "seed":
				seed_value = int(value)
			"--hours", "hours":
				hours = maxi(1, int(value))
			"--presets", "presets":
				presets = []
				for part in value.split(",", false):
					presets.append(String(part))
			"--mode", "mode":
				mode = value
	if mode != "fine" and mode != "coarse":
		printerr("measure_founding_ledger: --mode must be fine|coarse")
		quit(2)
		return
	for preset in presets:
		if not Difficulty.is_preset(preset):
			printerr("measure_founding_ledger: unknown preset " + preset)
			quit(2)
			return

	var rows: Dictionary = {}
	for preset in presets:
		rows[preset] = _measure(preset, seed_value, hours, mode)

	print("founding ledger · seed %d · mean of %d game-hour(s) · %s path · do_nothing"
			% [seed_value, hours, mode])
	print("")
	print("| preset | founding purse | gross $/gh | expense $/gh | net $/gh |")
	print("|---|---|---|---|---|")
	for preset in presets:
		var row: Dictionary = rows[preset]
		print("| `%s` | %d | %.2f | %.2f | **%+.2f** |" % [preset,
				int(row["purse"]), float(row["gross"]), float(row["expense"]),
				float(row["net"])])

	print("")
	print("| revenue line | " + " | ".join(presets) + " |")
	print("|---" .repeat(presets.size() + 1) + "|")
	for line in REVENUE_LINES:
		var cells: PackedStringArray = []
		for preset in presets:
			cells.append("%.2f" % float((rows[preset]["revenue"] as Dictionary).get(line, 0.0)))
		print("| `%s` | %s |" % [line, " | ".join(cells)])

	print("")
	var reference := String(presets[0])
	print("| expense line | " + " | ".join(presets) + " | ratio vs `%s` |" % reference)
	print("|---" .repeat(presets.size() + 2) + "|")
	for line in EXPENSE_LINES:
		var cells: PackedStringArray = []
		for preset in presets:
			cells.append("%.2f" % float((rows[preset]["expenses"] as Dictionary).get(line, 0.0)))
		var base := float((rows[reference]["expenses"] as Dictionary).get(line, 0.0))
		var last := float((rows[String(presets[-1])]["expenses"] as Dictionary).get(line, 0.0))
		var ratio := "—" if absf(base) < 1e-9 else "%.4f" % (last / base)
		print("| `%s` | %s | %s |" % [line, " | ".join(cells), ratio])
	var totals: PackedStringArray = []
	for preset in presets:
		totals.append("%.2f" % float(rows[preset]["expense"]))
	var base_total := float(rows[reference]["expense"])
	print("| **TOTAL** | %s | %.4f |" % [" | ".join(totals),
			float(rows[String(presets[-1])]["expense"]) / maxf(base_total, 1e-9)])
	quit(0)


## One preset. Advances a game-hour at a time and takes the MEAN of every line
## over the run, so `--hours=1` is §29.2's founding snapshot and `--hours=504` is
## the same ledger averaged over doc 92's 21-game-day horizon. A mean, not the
## last hour: past the founding hour the lines are noisy (one incident's fine,
## one hour of a pump on backup) and a single hour would report the noise.
func _measure(preset: String, seed_value: int, hours: int, mode: String) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, preset)
	var purse := sim.treasury.balance
	var revenue: Dictionary = {}
	var expenses: Dictionary = {}
	var gross := 0.0
	var expense := 0.0
	var net := 0.0
	for _h in hours:
		if mode == "coarse":
			sim.advance_coarse_hours(1, false)
		else:
			sim.advance_hours(1.0)
		var settled: Dictionary = sim.last_settlement
		var settled_revenue: Dictionary = settled.get("revenue", {})
		var settled_expenses: Dictionary = settled.get("expenses", {})
		for line in REVENUE_LINES:
			revenue[line] = float(revenue.get(line, 0.0)) \
					+ float(settled_revenue.get(line, 0.0))
		for line in EXPENSE_LINES:
			expenses[line] = float(expenses.get(line, 0.0)) \
					+ float(settled_expenses.get(line, 0.0))
		gross += float(settled_revenue.get("gross", 0.0))
		expense += float(settled_expenses.get("total", 0.0))
		net += float(settled.get("net", 0.0))
	var n := float(maxi(1, hours))
	for line in REVENUE_LINES:
		revenue[line] = float(revenue[line]) / n
	for line in EXPENSE_LINES:
		expenses[line] = float(expenses[line]) / n
	return {
		"purse": purse,
		"gross": gross / n,
		"expense": expense / n,
		"net": net / n,
		"revenue": revenue,
		"expenses": expenses,
	}
