extends SceneTree
## Doc 03 §2.8b's excavation yield, measured — the instrument doc 92 §66 is
## written from.
##
## It answers the four questions the ruling has to survive:
##
##   1. **The closed form.** Per terrain and distance: the block's own six-phase
##      bill, the published band (`works_yield_band`), the band as a percentage
##      of that bill, the same with the `copper` bonus on top, the ceiling in
##      dollars, and the ROAD_INSTALL share the ceiling has to stay under.
##   2. **The run.** Real cities, real seeds: buy a block, develop it end to end,
##      and report every find — phase, material, value, the cash/material split
##      and the running total against the ceiling.
##   3. **The yard.** How much material a development banks, what the next
##      phases take back off their invoice, and whether
##      `works_stockpile_cap()` is ever reached.
##   4. **The magnitude.** Dollars per game-day of `land_works` income across the
##      run, which is the number the balance gates re-fit against.
##
##   ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
##       -s res://tools/measure_land_works.gd -- [options]
##
##     --seeds=1337,4242,9001   cities to run          (default those three)
##     --blocks=3               blocks developed per city             (default 3)
##     --hours=720              game-hours per city                 (default 720)
##     --table-only             the closed form, no city run
##     --run-only               the city run, no closed form
##
## Like every `tools/measure_*.gd` this is a MEASURING instrument: it boots the
## real `CitySim`, uses the real commands, owns no constant of its own, and
## nothing in `sim/`, `game/` or `ui/` imports it.

const TERRAINS: Array[String] = ["flat", "gentle", "hilly", "steep", "rocky",
		"forest", "marsh", "island"]
const DISTANCES: Array[float] = [0.0, 4.0, 8.0]
const YIELD_PHASES: Array[String] = ["clearing", "grading", "utility_corridor"]


func _initialize() -> void:
	var seeds: Array[int] = [1337, 4242, 9001]
	var blocks := 3
	var hours := 720
	var table := true
	var run := true
	for raw: Variant in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(",", false):
				seeds.append(int(part))
		elif arg.begins_with("--blocks="):
			blocks = int(arg.substr(9))
		elif arg.begins_with("--hours="):
			hours = int(arg.substr(8))
		elif arg == "--table-only":
			run = false
		elif arg == "--run-only":
			table = false
	if table:
		_closed_form()
	if run:
		_run(seeds, blocks, hours)
	quit(0)


# --------------------------------------------------------------- closed form

func _closed_form() -> void:
	var sim := CitySim.boot_from_files(1337)
	if not sim.boot_errors.is_empty():
		printerr("boot: " + str(sim.boot_errors))
		quit(2)
		return
	var econ := sim.economy
	var cfg := econ.works_yield()
	print("\n== doc 03 §2.8b closed form ==")
	print("CEILING_FRACTION %.2f  BONUS %.2f @ %.0f%%  STOCKPILE_SHARE %.2f"
			% [float(cfg.get("CEILING_FRACTION", 0.0)), float(cfg.get("BONUS_MULT", 0.0)),
			100.0 * float(cfg.get("BONUS_CHANCE", 0.0)), econ.works_stockpile_share()])
	print("%-8s %3s %8s %7s %7s %7s %7s %8s %8s %8s"
			% ["terrain", "d", "bill", "low$", "high$", "low%", "high%", "bonus%",
			"ceil$", "road%"])
	var worst_road := 1.0
	var worst_bonus := 0.0
	for d: float in DISTANCES:
		for terrain: String in TERRAINS:
			var bill := econ.development_total_cost(terrain, d)
			var band := econ.works_yield_band(terrain, d)
			var bonus_high := 0
			for phase: String in YIELD_PHASES:
				bonus_high += econ.works_yield_value(phase, terrain, d, 0, 1.0, 1.0,
						phase == "utility_corridor")
			var road_share := float(econ.development_phase_cost("road_install", terrain, d)) \
					/ float(bill)
			worst_road = minf(worst_road, road_share)
			worst_bonus = maxf(worst_bonus, float(bonus_high) / float(bill))
			print("%-8s %3.0f %8d %7d %7d %6.2f%% %6.2f%% %7.2f%% %8d %7.2f%%"
					% [terrain, d, bill, int(band["low"]), int(band["high"]),
					100.0 * float(band["low"]) / float(bill),
					100.0 * float(band["high"]) / float(bill),
					100.0 * float(bonus_high) / float(bill),
					int(band["ceiling"]), 100.0 * road_share])
	print("\nbound 1  ceiling %.4f < min ROAD_INSTALL share %.4f  -> %s"
			% [float(cfg.get("CEILING_FRACTION", 0.0)), worst_road,
			"HOLDS" if float(cfg.get("CEILING_FRACTION", 0.0)) < worst_road else "FAILS"])
	print("bound 2  ceiling %.4f < SALVAGE_FRACTION %.4f  -> %s"
			% [float(cfg.get("CEILING_FRACTION", 0.0)), sim.econ_curves.salvage_fraction(),
			"HOLDS" if float(cfg.get("CEILING_FRACTION", 0.0))
					< sim.econ_curves.salvage_fraction() else "FAILS"])
	print("bound 3  max un-capped draw (high roll + bonus) %.4f of the bill"
			% worst_bonus)
	print("         -> the ceiling can only ever bite on the bonus tail: %s"
			% ("YES" if worst_bonus > float(cfg.get("CEILING_FRACTION", 0.0)) else "NO"))
	print("yard cap $%d = %.2f x (road_install + utility_corridor, flat, d=0) $%d"
			% [econ.works_stockpile_cap(),
			float(cfg.get("STOCKPILE_MAX_OFFSET_FRACTION", 0.0)),
			econ.development_phase_cost("road_install", "flat", 0.0)
					+ econ.development_phase_cost("utility_corridor", "flat", 0.0)])
	sim.dispose()


# ----------------------------------------------------------------- the run

func _run(seeds: Array[int], blocks: int, hours: int) -> void:
	print("\n== the run: %d cities x %d blocks x %d game-hours =="
			% [seeds.size(), blocks, hours])
	var finds := 0
	var value_total := 0
	var cash_total := 0
	var banked_total := 0
	var offset_total := 0
	var bonus_count := 0
	var capped_count := 0
	var block_bills: Array[int] = []
	var block_yields: Array[int] = []
	var yard_peak := 0
	var game_days := 0.0
	for seed_value: int in seeds:
		var sim := CitySim.boot_from_files(seed_value)
		if not sim.boot_errors.is_empty():
			printerr("boot: " + str(sim.boot_errors))
			quit(2)
			return
		# Money is not the thing under measurement; the yield is. A treasury that
		# runs out mid-pipeline would measure doc 03 §2.10's ladder instead.
		sim.treasury.balance = 50_000_000
		var bought: Array[String] = []
		for i in blocks:
			var id := _next_purchasable(sim)
			if id == "":
				break
			var result := sim.cmd_buy_block(id, false, true)
			if bool(result["ok"]):
				bought.append(id)
		# The shell's own drain, done here: advance an hour, take the batch,
		# keep the two rows this tool is about. `bus.observer` belongs to
		# `CitySim`'s fan-out and a tool may not take it (constitution §3).
		var log_rows: Array[Dictionary] = []
		for _h in hours:
			sim.advance_hours(1.0)
			for event: Dictionary in sim.bus.drain():
				var kind := String(event.get("type", ""))
				if kind == "land_works_find" or kind == "land_works_stockpile_spent":
					log_rows.append(event)
		game_days += float(hours) / 24.0
		for row: Dictionary in log_rows:
			if String(row["type"]) == "land_works_stockpile_spent":
				offset_total += int(row["amount"])
				continue
			finds += 1
			value_total += int(row["value"])
			cash_total += int(row["amount"])
			banked_total += int(row["stockpiled"])
			yard_peak = maxi(yard_peak, int(row["stockpile"]))
			if bool(row.get("bonus", false)):
				bonus_count += 1
			if bool(row.get("capped", false)):
				capped_count += 1
			print("  seed %5d  %-16s %-9s %-9s value $%6d  cash $%6d  yard $%5d"
					% [seed_value, String(row["block"]) + " " + String(row["phase"]),
					String(row["material"]), "BONUS" if bool(row["bonus"]) else "",
					int(row["value"]), int(row["amount"]), int(row["stockpiled"])])
		for id: String in bought:
			var block := sim.world.block(id)
			var bill := sim.economy.development_total_cost(String(block.dev_terrain),
					float(sim.world.d_from_center(id)), block.arterial_connections,
					float(sim.treasury.difficulty().get("M_dev", 1.0)))
			block_bills.append(bill)
			block_yields.append(block.works_yield_total)
			print("  seed %5d  block %-4s %-8s state %-18s bill $%7d  recovered $%6d (%.2f%%)"
					% [seed_value, id, String(block.dev_terrain),
					String(block.development_state), bill, block.works_yield_total,
					0.0 if bill <= 0 else 100.0 * float(block.works_yield_total) / float(bill)])
		yard_peak = maxi(yard_peak, sim.works_stockpile)
		sim.dispose()

	print("\nfinds %d   value $%d   cash $%d   material $%d   yard spent $%d"
			% [finds, value_total, cash_total, banked_total, offset_total])
	print("bonus fired %d/%d finds (%.1f%%)   ceiling clamped %d finds"
			% [bonus_count, finds, 0.0 if finds == 0 else 100.0 * float(bonus_count)
					/ float(finds), capped_count])
	print("yard peak $%d   cap $%d" % [yard_peak, _cap()])
	var worst := 0.0
	for i in block_bills.size():
		if block_bills[i] > 0:
			worst = maxf(worst, float(block_yields[i]) / float(block_bills[i]))
	print("worst single block recovered %.2f%% of its own development bill"
			% (100.0 * worst))
	print("magnitude: $%.2f of land_works income per game-day across %.1f game-days"
			% [0.0 if game_days <= 0.0 else float(cash_total) / game_days, game_days])


func _cap() -> int:
	var sim := CitySim.boot_from_files(1337)
	var cap := sim.economy.works_stockpile_cap()
	sim.dispose()
	return cap


## The cheapest block the city is allowed to buy right now, or `""`.
func _next_purchasable(sim: CitySim) -> String:
	var best := ""
	var best_price := 0
	for id: String in sim.world.block_ids_sorted():
		var block := sim.world.block(id)
		if block.ownership_state != &"PURCHASABLE":
			continue
		if not bool(sim.world.purchase_allowed(id, sim.progression.city_level)["ok"]):
			continue
		var price := sim.economy.land_price(sim.land_price_inputs(id))
		if best == "" or price < best_price:
			best = id
			best_price = price
	return best
