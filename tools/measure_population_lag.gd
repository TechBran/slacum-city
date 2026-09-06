extends SceneTree
## Wave-24 Lane-2 instrument (doc 92 §64, report 98 §67).
## **HOW LONG, IN REAL SECONDS, BETWEEN "I PLACED A HOUSE" AND "THE NUMBER ON MY
## SCREEN CHANGED"?**
##
## The player's report of 2026-09-04 is a LATENCY report, not an arithmetic one:
## *"As I'm building up houses and have new residents that pop up, I don't get an
## increase in population like people. I don't see it actually counting up."*
## Every previous probe of this asked the sim what the population WAS. This one
## asks when the player would have SEEN it move, which is a different number and
## the only one the report is about.
##
## It boots the real `CitySim`, places a real building through the real
## `cmd_place_building`, and then steps the real FINE path one SimTick at a time,
## sampling per game-minute:
##
##   * the building's `state` and `level`
##   * its age in game-hours since `built_at_minutes`
##   * `Building.state_occupancy()` — the state gate
##   * `PopulationSystem.ramp(age_h)` — what doc 09's ramp WOULD say, beside
##     `_population_inputs`' hard-coded `age_hours` (they disagree; that is RR-204)
##   * `population.occ_of(id)` — the settled per-building occupancy
##   * `occupied_population` (float) and `city_population` (int)
##   * the exact string `ui/hud.gd` would paint in the population chip, via the
##     real `HudModel.chip_values`
##
## `data/time.json` sets `real_seconds_per_game_minute = 1.0`, so at 1× speed one
## game-minute IS one real second and the table's `real_s` column is literal
## wall-clock seconds of play. At 2×/3× divide by the speed.
##
##   ~/.local/bin/godot --headless --path <repo> \
##       -s res://tools/measure_population_lag.gd -- [options]
##
##   --archetype=ID   what to place (default `house`)
##   --warm=N         game-hours to settle the city before placing (default 3;
##                    3 is the first hour at which the booted city reads its
##                    honest population — see `--boot` below)
##   --offset-min=N   game-minutes past the hour boundary to place at
##                    (default 5 — a player does not tap on the hour)
##   --minutes=N      game-minutes to watch after the placement (default 360)
##   --stride=N       print every Nth minute row (default 15; events always print)
##   --rows           print the whole per-minute table instead of the summary
##   --boot           ALSO run the boot/load arm: what the chip reads at t=0 on
##                    a fresh boot and immediately after a save restore
##   --houses=N       ALSO run the session arm: place one building an hour for N
##                    game-hours and print the census on every settle — the
##                    PLURAL in the player's report ("as I'm building up
##                    houses"), and the arm that would catch an attractiveness
##                    drift swallowing a placement
##   --happiness=N    HOLD `HappinessModel.happiness` at N through the session
##                    arm, which drives doc 09 §2.10.2's ceiling down and makes
##                    `attractiveness` fall hour by hour — the one arithmetic
##                    way a placement CAN be swallowed. `--happiness=20` is the
##                    measurement published in doc 92 §64.5
##   --seed=N         RNG seed (default 1337)
##   --json=FILE      write the run as JSON
##
## It is a MEASURING instrument (constitution §3): it boots the real `CitySim`,
## owns no balance constant, and is never imported by `sim/`.

## `data/time.json.clock.real_seconds_per_game_minute` at 1× speed. Restated
## here as a PRESENTATION factor only — this tool prices no rule, and the file
## stays the authority (asserted in `_check_real_seconds`).
## RR-239's one site search, shared (Wave 29 fix).
const SiteSearch := preload("res://tools/site_search.gd")

const REAL_SECONDS_PER_GAME_MINUTE := 1.0
const TIME_PATH := "res://data/time.json"


func _initialize() -> void:
	var archetype := "house"
	var warm := 3.0
	var offset_min := 5
	var minutes := 360
	var stride := 15
	var rows := false
	var boot_arm := false
	var houses := 0
	var happiness := -1.0
	var seed_value := 1337
	var json_path := ""
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--archetype="):
			archetype = text.substr(12)
		elif text.begins_with("--warm="):
			warm = float(text.substr(7))
		elif text.begins_with("--offset-min="):
			offset_min = int(text.substr(13))
		elif text.begins_with("--minutes="):
			minutes = int(text.substr(10))
		elif text.begins_with("--stride="):
			stride = maxi(1, int(text.substr(9)))
		elif text == "--rows":
			rows = true
		elif text == "--boot":
			boot_arm = true
		elif text.begins_with("--houses="):
			houses = int(text.substr(9))
		elif text.begins_with("--happiness="):
			happiness = float(text.substr(12))
		elif text.begins_with("--seed="):
			seed_value = int(text.substr(7))
		elif text.begins_with("--json="):
			json_path = text.substr(7)
		else:
			printerr("measure_population_lag: unknown option " + text)
			quit(2)
			return

	_check_real_seconds()
	var out: Dictionary = {"archetype": archetype, "warm_hours": warm,
			"offset_minutes": offset_min, "seed": seed_value}
	if boot_arm:
		out["boot"] = _boot_arm(seed_value)
	if houses > 0:
		out["session"] = _session_arm(seed_value, archetype, houses, happiness)
	out["place"] = _place_arm(seed_value, archetype, warm, offset_min, minutes,
			stride, rows)
	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(out, "  "))
	quit(0)


## The file is the authority for the real-seconds conversion; a drift would make
## every `real_s` column in this tool's output a lie, so it is asserted out loud
## rather than trusted.
func _check_real_seconds() -> void:
	var clock_block: Dictionary = StarterCityLoader.read_json(TIME_PATH).get("clock", {})
	var authored := float(clock_block.get("real_seconds_per_game_minute",
			REAL_SECONDS_PER_GAME_MINUTE))
	if absf(authored - REAL_SECONDS_PER_GAME_MINUTE) > 0.0001:
		printerr("measure_population_lag: data/time.json says %f real s/game-min, "
				% authored + "this tool prints %f" % REAL_SECONDS_PER_GAME_MINUTE)


# ---------------------------------------------------------------- the boot arm

## "A freshly booted or freshly loaded city reads 0 until the first hourly
## settle." Measured, on both doors into a city.
func _boot_arm(seed_value: int) -> Dictionary:
	print("")
	print("=== BOOT / LOAD ARM — what the chip reads before the first settle ===")
	var sim := CitySim.boot_from_files(seed_value)
	var hud := HudModel.new()
	var row := func(label: String, s: CitySim) -> Dictionary:
		var chip: Dictionary = hud.chip_values({"population": s.population.city_population})
		var text := String((chip["population"] as Dictionary)["text_full"])
		print("  %-34s city_population=%-6d occupied=%-9.3f chip=%s"
				% [label, s.population.city_population,
				s.population.occupied_population, text])
		return {"label": label, "city_population": s.population.city_population,
				"occupied_population": s.population.occupied_population, "chip": text}
	var samples: Array = []
	samples.append(row.call("fresh boot, before tick 0", sim))
	sim.scheduler.advance_fine_n(1)
	samples.append(row.call("fresh boot, after ONE SimTick", sim))
	sim.advance_hours(3.0)
	var settled := sim.population.city_population
	samples.append(row.call("boot + 3 game-hours", sim))

	# A save taken MID-HOUR is the ordinary case — the player leaves when the
	# player leaves. The next hourly settle is then up to 59 game-minutes (= 59
	# REAL seconds at 1x) away, and the whole of that window reads zero.
	print("")
	sim.advance_hours(5.0 / 60.0)
	var body := sim.capture_state()
	print("  save taken at tick %d (%d ticks past the hour boundary)"
			% [sim.clock.tick_index, sim.clock.tick_index % GameClock.TICKS_PER_HOUR])
	var loaded := CitySim.boot_from_files(seed_value)
	loaded.restore_state(body)
	samples.append(row.call("mid-hour SAVE/LOAD, before tick", loaded))
	var zero_ticks := 0
	for i in GameClock.TICKS_PER_HOUR + 1:
		if loaded.population.city_population != 0:
			break
		loaded.scheduler.advance_fine_n(1)
		zero_ticks += 1
	samples.append(row.call("...first tick that reports it", loaded))
	var zero_seconds := float(zero_ticks) * float(GameClock.GAME_SECONDS_PER_TICK) \
			/ 60.0 * REAL_SECONDS_PER_GAME_MINUTE
	print("  → a %d-person city reads 0 for %d ticks = %.0f REAL SECONDS after the load"
			% [settled, zero_ticks, zero_seconds])
	return {"settled": settled, "zero_ticks_after_load": zero_ticks,
		"zero_real_seconds_after_load": zero_seconds, "samples": samples}


# ------------------------------------------------------------- the session arm

## **"As I'm building up houses…"** — the plural in the report. One house every
## game-hour, and the census printed on every settle, so the question the player
## is actually asking ("does what I am doing show up?") is answered as a
## trajectory rather than as one event.
##
## It is also the arm that would catch the one arithmetic way the counter could
## swallow a placement: `occupied_population` is recomputed from scratch each
## hour and multiplied by the CURRENT `attractiveness`, so a city whose
## attractiveness is drifting DOWN can absorb a new house's residents entirely —
## 144 × 0.97 + 4 × 0.97 ≈ 143.6, which `roundi` prints as 144 and the player
## reads as "nothing happened". The `A_city` column is there to be watched.
func _session_arm(seed_value: int, archetype: String, houses: int,
		happiness: float) -> Dictionary:
	print("")
	print("=== SESSION ARM — one %s an hour for %d game-hours%s ==="
			% [archetype, houses,
			"" if happiness < 0.0 else ", happiness held at %.0f" % happiness])
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(1.0)
	var hud := HudModel.new()
	print("  %5s %6s %8s %10s %8s %7s  %s"
			% ["gh", "real_s", "placed", "occupied", "A_city", "pop", "chip"])
	var rows: Array = []
	var placed_total := 0
	var prev := sim.population.city_population
	for h in houses + 4:  # four quiet hours after the last tap, to see it land
		if h < houses:
			var lot := _serviceable_lot(sim, archetype)
			if lot.x >= 0 and bool(sim.cmd_place_building(archetype, lot)["ok"]):
				placed_total += 1
		if happiness >= 0.0:
			sim.happiness.happiness = happiness
		sim.advance_hours(1.0)
		var pop_now := sim.population.city_population
		var chip: Dictionary = hud.chip_values({"population": pop_now})
		print("  %5d %6.0f %8d %10.3f %8.4f %7d  %s%s"
				% [h + 1, float(h + 1) * 60.0 * REAL_SECONDS_PER_GAME_MINUTE,
				placed_total, sim.population.occupied_population,
				sim.population.attractiveness, pop_now,
				String((chip["population"] as Dictionary)["text_full"]),
				"" if pop_now != prev else "   <-- the number did not move"])
		rows.append({"game_hour": h + 1, "placed": placed_total,
			"occupied_population": sim.population.occupied_population,
			"attractiveness": sim.population.attractiveness,
			"city_population": pop_now})
		prev = pop_now
	return {"placed": placed_total, "rows": rows}


# --------------------------------------------------------------- the place arm

func _place_arm(seed_value: int, archetype: String, warm: float, offset_min: int,
		minutes: int, stride: int, rows: bool) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(warm)
	if offset_min > 0:
		sim.advance_hours(float(offset_min) / 60.0)
	var lot := _serviceable_lot(sim, archetype)
	if lot.x < 0:
		printerr("measure_population_lag: no serviceable vacant lot for " + archetype)
		return {"error": "no lot"}
	var pop_before := sim.population.city_population
	var occ_before := sim.population.occupied_population
	var placed := sim.cmd_place_building(archetype, lot)
	if not bool(placed["ok"]):
		printerr("measure_population_lag: placement refused: "
				+ String(placed.get("reason_code", "")))
		return {"error": String(placed.get("reason_code", ""))}
	var payload: Dictionary = placed["payload"]
	var sim_id := String(payload["sim_id"])
	var b: Building = sim.buildings[sim_id]
	var authored_pop := int(b.stats.get("population", 0))
	var place_minute := sim.clock.sim_time_minutes()

	print("")
	print("=== PLACE ARM — %s at %s, %d authored residents ==="
			% [archetype, str(lot), authored_pop])
	print("  warm-up %.2f gh + %d min; city_population before the tap = %d (%.3f occupied)"
			% [warm, offset_min, pop_before, occ_before])
	print("")
	print("  %6s %6s %5s  %-18s %3s %6s %7s %7s %6s %10s %6s  %s"
			% ["real_s", "gmin", "gh", "state", "lvl", "age_h", "st_occ",
			"doc_ramp", "occ_b", "occupied", "pop", "chip"])

	var hud := HudModel.new()
	var samples: Array = []
	var t_complete := -1
	var t_first_change := -1
	var t_full := -1
	var prev_pop := pop_before
	for m in range(1, minutes + 1):
		sim.advance_hours(1.0 / 60.0)
		var age_h := float(sim.clock.sim_time_minutes() - b.built_at_minutes) / 60.0
		var pop_now := sim.population.city_population
		var event := ""
		if t_complete < 0 and b.state == &"active":
			t_complete = m
			event = "  <-- CONSTRUCTION COMPLETE"
		if t_first_change < 0 and pop_now != prev_pop:
			t_first_change = m
			event += "  <-- THE NUMBER ON SCREEN MOVES (%d -> %d)" % [prev_pop, pop_now]
		if t_full < 0 and pop_now >= pop_before + authored_pop:
			t_full = m
			event += "  <-- all %d residents counted" % authored_pop
		var chip: Dictionary = hud.chip_values({"population": pop_now})
		var line := "  %6.0f %6d %5.2f  %-18s %3d %6.2f %7.2f %7.2f %6.3f %10.3f %6d  %s%s" \
				% [float(m) * REAL_SECONDS_PER_GAME_MINUTE, m, float(m) / 60.0,
				String(b.state), b.level, age_h, b.state_occupancy(),
				PopulationSystem.ramp(age_h), sim.population.occ_of(sim_id),
				sim.population.occupied_population, pop_now,
				String((chip["population"] as Dictionary)["text_full"]), event]
		if rows or event != "" or m % stride == 0:
			print(line)
		samples.append({"minute": m, "state": String(b.state), "level": b.level,
				"age_h": age_h, "state_occupancy": b.state_occupancy(),
				"occ_b": sim.population.occ_of(sim_id),
				"occupied_population": sim.population.occupied_population,
				"city_population": pop_now})
		prev_pop = pop_now

	print("")
	print("  --- THE FINDING, in REAL SECONDS at 1x speed ---")
	print("    placed                                       ->    0 s")
	_report("    shell finishes (state = active)             ", t_complete)
	_report("    the population chip changes                 ", t_first_change)
	_report("    the chip shows all %2d residents             " % authored_pop, t_full)
	print("    attractiveness at the settle                 -> %.4f"
			% sim.population.attractiveness)
	print("    one %s is worth %.3f people at that attractiveness"
			% [archetype, float(authored_pop) * sim.population.attractiveness])
	print("    doc 09 ramp at completion (UNUSED by CitySim) -> %.3f"
			% PopulationSystem.ramp(float(t_complete) / 60.0 if t_complete > 0 else 0.0))
	return {"lot": [lot.x, lot.y], "sim_id": sim_id, "authored_population": authored_pop,
		"population_before": pop_before, "minute_placed": place_minute,
		"minutes_to_complete": t_complete, "minutes_to_first_change": t_first_change,
		"minutes_to_full": t_full, "attractiveness": sim.population.attractiveness,
		"samples": samples}


func _report(label: String, minute: int) -> void:
	if minute < 0:
		print("%s-> NEVER inside the window" % label)
		return
	print("%s-> %4d s  (%.2f game-hours)"
			% [label, roundi(float(minute) * REAL_SECONDS_PER_GAME_MINUTE),
			float(minute) / 60.0])


## The same scan `tests/test_city_commands.gd` uses: a buildable, vacant,
## power-serviceable site inside the core, sized to the LOT the command reserves
## (Wave 29 fix, RR-239). At the level-1 footprint this handed
## `cmd_place_building` a site it refuses, and the latency this instrument
## publishes would have silently become the latency of a refusal.
static func _serviceable_lot(sim: CitySim, archetype: String) -> Vector2i:
	return SiteSearch.serviceable_site(sim, archetype)
