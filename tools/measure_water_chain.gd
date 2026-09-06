extends SceneTree
## **THE WATER CHAIN, WALKED — doc 05 §2.1–§2.8 against `sim/water/`.**
##
## The player's sentence was *"my volume is starting to get low"*, and a
## sentence like that has to have a MEASURED cause before anything is fixed.
## Doc 05 §2.5 makes supply the minimum of four terms —
##
##     S(z) = min( Σ min(rated · power · condition, upstream share) , feed_capacity )
##            where share is split out of  upstream = min(Σ source, Σ treatment)
##
## — and until `WaterSystem.supply_chain()` no reader in the project computed
## all four. This tool prints them, per game-day, per zone, beside the demand
## they are measured against and the per-tile pressure SPREAD inside the zone
## (doc 92 §67.8's finding: six different pressures in one zone at pressure
## 1.00, because §2.3's factor is distance to a pipe and not supply at all).
##
##   ~/.local/bin/godot --headless --path . \
##       -s res://tools/measure_water_chain.gd -- [options]
##
##   --days=N        game-days to advance                    (default 25)
##   --seeds=a,b     seeds to run, `tools/measure_curriculum.gd`'s own
##                                                           (default 1337)
##   --strategy=ID   playtest strategy                       (default curriculum)
##   --stride=N      print a chain table every N game-days   (default 5)
##   --saves=DIR     INSTEAD of a generated arc: load a real slot out of DIR
##                   through the real `SaveService`, into a PRIVATE `user://`
##                   (never the live one). `--slot=N` picks the slot.
##   --slot=N        slot for `--saves`                      (default 0)
##   --spread        per-building pressure histogram inside every live zone
##   --losses        the volume ledger: every place a m³/h is capped or lost,
##                   and whether doc 05 calls it a rule
##   --shop          quote every purchase that would move this city's water:
##                   the repairs it owes, the rung under the stage that binds,
##                   and what each one costs — the ARM that answers "what would
##                   the player have to buy, and for how much"
##   --buy           …and then buy them, and re-measure. The acceptance test for
##                   a fix is the city AFTER the player has spent the money.
##   --step-one      with `--saves`: drive the player's first sentence end to
##                   end — enter the SOURCE card, read the window, follow its
##                   own advice (buy the block, run the pipe, move to the
##                   shoreline), place source → treatment → pump, and print
##                   every move and every dollar
##   --quiet         tables only
##
## It is a MEASURING instrument (constitution §3): it boots the real `CitySim`,
## drives the real scheduler, owns no constant of its own and is never imported
## by `sim/`.

const Playtest := preload("res://tools/playtest.gd")

const HOURS_PER_DAY := 24
const DEFAULT_DAYS := 25
const DEFAULT_STRIDE := 5
## Marks the private `user://` the `--saves` arm creates, and the ONLY path its
## sweep will touch — `tools/measure_player_city.gd`'s guard, restated because a
## tool in `tools/` may not import another tool's constant.
const DIR_MARK := "slacum-waterchain-"

var _user_dir: String = ""


func _initialize() -> void:
	var days := DEFAULT_DAYS
	var seeds: Array[int] = [1337]
	var strategy := "curriculum"
	var stride := DEFAULT_STRIDE
	var saves := ""
	var slot := 0
	var spread := false
	var losses := false
	var shop := false
	var buy := false
	var quiet := false
	var step_one := false
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--seeds="):
			seeds = [] as Array[int]
			for part in arg.substr(8).split(",", false):
				seeds.append(int(part))
		elif arg.begins_with("--strategy="):
			strategy = arg.substr(11)
		elif arg.begins_with("--stride="):
			stride = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--saves="):
			saves = arg.substr(8)
		elif arg.begins_with("--slot="):
			slot = int(arg.substr(7))
		elif arg == "--spread":
			spread = true
		elif arg == "--losses":
			losses = true
		elif arg == "--shop":
			shop = true
		elif arg == "--buy":
			shop = true
			buy = true
		elif arg == "--quiet":
			quiet = true
		elif arg == "--step-one":
			step_one = true

	if saves != "" and step_one:
		_run_step_one(saves, slot)
		quit(0)
		return
	if saves != "":
		_run_save(saves, slot, days, stride, spread, losses, shop, buy)
		quit(0)
		return
	for seed_value in seeds:
		_run_arc(strategy, seed_value, days, stride, spread, losses, shop, quiet)
	quit(0)


# ------------------------------------------------------------------ the arcs

## A generated city, grown by the same agent `tools/measure_curriculum.gd` uses,
## sampled every `stride` game-days. The loop body is
## `tests/balance_gate_rig.gd`'s (online, coarse) rather than a copy: a chain
## measured on a different city from the gates would not be the same chain.
func _run_arc(strategy_id: String, seed_value: int, days: int, stride: int,
		spread: bool, losses: bool, shop: bool, quiet: bool) -> void:
	var sim := CitySim.boot_from_files(seed_value)
	var strategy := Playtest.Factory.make(strategy_id)
	var api := Playtest.Api.new(sim)
	sim.bus.drain()
	print("")
	print("=== water chain: strategy=%s seed=%d days=%d ===" % [strategy_id, seed_value, days])
	_print_chain(sim, 0, spread)
	for h in days * HOURS_PER_DAY:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		sim.bus.drain()
		var day := (h + 1) / HOURS_PER_DAY
		if (h + 1) % (HOURS_PER_DAY * stride) == 0:
			_print_chain(sim, day, spread)
	if not quiet:
		print("")
		print("population %d  treasury $%s  water nodes %d  mains %d"
				% [int(sim.population.city_population), _money(sim.treasury.balance),
				_facility_count(sim), sim.water.edges.size()])
	if losses:
		_print_losses(sim)
	if shop:
		_print_shop(sim)
	sim.dispose()


## The real slot, through the real `SaveService`, into a private `user://`.
func _run_save(saves: String, slot: int, days: int, stride: int,
		spread: bool, losses: bool, shop: bool, buy: bool) -> void:
	_isolate_user_dir()
	if _copy_saves(saves) == 0:
		printerr("measure_water_chain: nothing copied out of " + saves)
		_sweep()
		return
	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	root.add_child(service)
	if not service.load_slot(sim, slot):
		printerr("measure_water_chain: slot %d did not load" % slot)
		root.remove_child(service)
		service.free()
		sim.dispose()
		_sweep()
		return
	# The head-align `tools/measure_player_city.gd` documents: a save is written
	# when the player pauses, so its `sim_time_minutes` is almost never on an
	# hour boundary and `advance_coarse_n` asserts alignment.
	var misalign := sim.clock.tick_index % GameClock.TICKS_PER_HOUR
	if misalign != 0:
		sim.scheduler.advance_fine_n(GameClock.TICKS_PER_HOUR - misalign)
	sim.bus.drain()
	print("")
	print("=== water chain: THE PLAYER'S SAVE, slot %d ===" % slot)
	print("population %d  treasury $%s  buildings %d  water nodes %d  mains %d"
			% [int(sim.population.city_population), _money(sim.treasury.balance), sim.buildings.size(),
			_facility_count(sim), sim.water.edges.size()])
	_print_nodes(sim)
	_print_chain(sim, 0, spread)
	if losses:
		_print_losses(sim)
	if shop:
		_print_shop(sim)
	if buy:
		_buy_the_list(sim)
		print("")
		print("=== AFTER the purchases, and after the crews finish ===")
		_print_chain(sim, 0, spread)
	for day in range(1, days + 1):
		sim.advance_coarse_hours(HOURS_PER_DAY, false)
		sim.bus.drain()
		if day % stride == 0 or day == days:
			_print_chain(sim, day, spread)
	if losses:
		_print_losses(sim)
	root.remove_child(service)
	service.free()
	sim.dispose()
	_sweep()


# ---------------------------------------------------------------- the tables

## §2.5's four terms, the two numbers they produce, and the stage that BINDS.
func _print_chain(sim: CitySim, day: int, spread: bool) -> void:
	print("")
	print("-- game-day %d --" % day)
	print("| zone | source | treat | upstr | pump rated | pump DELIV | mains "
			+ "| SUPPLY | demand | press | headroom | BINDS | next | stranded |")
	for raw: Variant in sim.water.supply_chains():
		var c: Dictionary = raw
		if not bool(c["live"]) and float(c["demand_m3h"]) <= 0.0:
			continue
		print("| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.2f | %.1f | %s %.1f | %s %.1f | %.1f |"
				% [c["zone_key"], c["source_m3h"], c["treatment_m3h"], c["upstream_m3h"],
				c["pump_rated_m3h"], c["pump_m3h"], c["mains_m3h"],
				c["supply_m3h"], c["demand_m3h"], c["pressure"], c["headroom_m3h"],
				c["binding"], c["binding_m3h"], c["next_binding"],
				c["next_binding_m3h"], c["stranded_m3h"]])
	var city: Dictionary = sim.water.get_overlay_snapshot()["city"]
	print("city: demand %.1f  supply %.1f  storage %.0f/%.0f (%.0f%%)  health %d%%  deficit zones %d"
			% [city["total_demand_m3h"], city["total_supply_m3h"],
			city["total_storage_m3"], city["storage_capacity_m3"],
			100.0 * float(city["storage_frac"]), int(city["water_health_pct"]),
			int(city["zones_in_deficit"])])
	if spread:
		_print_spread(sim)


## §2.3's per-tile factor, read where the player meets it: at the access tile of
## every building the zone serves. `P_tile = zone.pressure × tile_factor`, so a
## spread inside ONE zone is entirely distance-to-a-main and the gate that
## refuses at 0.55 is refusing about pipes.
func _print_spread(sim: CitySim) -> void:
	var per_zone: Dictionary = {}
	# **Wave 30: the same census, split by REMEDY** (doc 93 §BH). "46 of 89 are
	# under the gate" is the shape of the problem; "and every one of them is a
	# PIPE" is the answer, and until `WaterSystem.pressure_remedy_at` existed no
	# reader could say which. Counted per zone because the classification is per
	# zone: a zone at or above the gate refuses for distance and a zone under it
	# refuses for supply, and the same tile can be either as the works moves.
	var per_zone_far: Dictionary = {}
	for raw: Variant in sim.water.demand.sorted_ids():
		var building_id := String(raw)
		var tile: Vector2i = sim.water.demand.access_tile(building_id)
		var z: PressureZone = sim.water.zone_at(tile)
		if z == null:
			continue
		if not per_zone.has(z.zone_key):
			per_zone[z.zone_key] = []
			per_zone_far[z.zone_key] = 0
		(per_zone[z.zone_key] as Array).append(sim.water.pressure_at(tile))
		if sim.water.pressure_at(tile) < sim.water.data.effect("upgrade_min_pressure", 0.55) \
				and sim.water.pressure_remedy_at(tile) == WaterSystem.BLOCKED_DISTANCE:
			per_zone_far[z.zone_key] = int(per_zone_far[z.zone_key]) + 1
	var gate := sim.water.data.effect("upgrade_min_pressure", 0.55)
	for key: Variant in _sorted_keys(per_zone):
		var values: Array = per_zone[key]
		values.sort()
		var under := 0
		for value: float in values:
			if value < gate:
				under += 1
		var far := int(per_zone_far[key])
		print("  spread %s: n=%d  min %.2f  p25 %.2f  median %.2f  max %.2f  | under the %.2f upgrade gate: %d (%.0f%%) — %d want a MAIN, %d want SUPPLY"
				% [key, values.size(), values[0], values[values.size() / 4],
				values[values.size() / 2], values[-1], gate, under,
				100.0 * float(under) / float(values.size()), far, under - far])


## Every doc-05 node the city owns, with the rung it is on and the rung the MVP
## roster lets it reach — the ladder the player is standing on.
func _print_nodes(sim: CitySim) -> void:
	print("| node | variant | L | cap (MVP) | rated m³/h | kW | state | cond | zone |")
	for raw: Variant in _sorted_keys(sim.water.nodes):
		var node: WaterNode = sim.water.nodes[raw]
		if node.variant == &"junction":
			continue
		var record: Dictionary = sim.water.data.component(node.variant, node.level, node.subtype)
		var rated := float(record.get("rated_flow_m3h", record.get("throughput_m3h",
				record.get("yield_m3h", record.get("capacity_m3", 0.0)))))
		var levels: Array = (sim.water.data.placeable_rules(String(node.variant))
				.get("placeable_levels", []) as Array)
		var top := node.level
		for entry: Variant in levels:
			top = maxi(top, int(entry))
		var z: PressureZone = sim.water.topology.zone_of(String(raw))
		print("| %s | %s | %d | %d | %.1f | %.0f | %s | %.2f | %s |"
				% [raw, node.variant, node.level, top, rated,
				sim.water.data.kw_required(node.variant, node.level, node.subtype),
				node.state, node.condition, z.zone_key if z != null else "—"])


## **The volume ledger.** Every place doc 05 caps or loses a m³/h, with the
## amount and the section that authorises it. A row with no section is a defect.
func _print_losses(sim: CitySim) -> void:
	print("")
	print("-- where the volume goes --")
	for raw: Variant in sim.water.supply_chains():
		var c: Dictionary = raw
		if not bool(c["live"]):
			continue
		var key: String = c["zone_key"]
		var source: float = c["source_m3h"]
		var treatment: float = c["treatment_m3h"]
		var upstream: float = c["upstream_m3h"]
		var available: float = c["pump_available_m3h"]
		var delivering: float = c["pump_m3h"]
		var supply: float = c["supply_m3h"]
		print("  %s: raw intake %.1f" % [key, source])
		if treatment < source:
			print("      −%.1f  treatment throughput (§2.5 upstream = min(source, treatment)) — RULE"
					% (source - treatment))
		if available < upstream:
			print("      −%.1f  pump rated·power·condition below upstream (§2.5) — RULE"
					% (upstream - available))
		if delivering < minf(upstream, available) - 0.01:
			print("      (of which %.1f is the share split, below)" % (minf(upstream, available) - delivering))
		if float(c["stranded_m3h"]) > 0.01:
			print("      −%.1f  STRANDED: upstream share held by a pump that is not running (§2.5 splits at TOPOLOGY time, runs at TICK time) — NO SECTION AUTHORISES THIS"
					% float(c["stranded_m3h"]))
		if float(c["mains_m3h"]) < delivering - 0.01:
			print("      −%.1f  feed_capacity min-cut (§2.5) — RULE"
					% (delivering - float(c["mains_m3h"])))
		print("      = supply %.1f against demand %.1f" % [supply, c["demand_m3h"]])
		var z: PressureZone = sim.water.topology.zone_by_key(key)
		if z != null and z.leak_m3h > 0.0:
			print("      +%.1f  leak from broken mains, charged to DEMAND (§2.4) — RULE"
					% z.leak_m3h)
		if z != null and z.break_penalty > 0.0:
			print("      P = ratio^1.3 × head − break_pen: %.2f = %.2f − %.2f%s (§2.8)"
					% [z.pressure, pow(z.ratio, 1.3), z.break_penalty,
					"  ** AT THE 0.50 CAP **" if z.break_penalty >= 0.4999 else ""])
	_print_breaks(sim)


## Every broken or isolated main, the leak it is charged for, and the repair job
## that is (or is NOT) working on it. A break with no job is water leaving the
## city with nothing in the game moving to stop it.
func _print_breaks(sim: CitySim) -> void:
	var rows: Array = []
	for raw: Variant in _sorted_keys(sim.water.edges):
		var e: WaterEdge = sim.water.edges[raw]
		if e.state == &"ok":
			continue
		rows.append(raw)
	if rows.is_empty():
		return
	print("")
	print("-- mains not OK: %d of %d --" % [rows.size(), sim.water.edges.size()])
	print("| main | tier | state | sev | cond | leak m³/h | penalty | owning incident | job | work left | crew |")
	for raw: Variant in rows:
		var e: WaterEdge = sim.water.edges[raw]
		var job: Dictionary = sim.water.repairs.job_for_target(String(raw))
		print("| %s | %s | %s | %.2f | %.2f | %.1f | %.2f | %s | %s | %s | %s |"
				% [raw, e.tier, e.state, e.severity, e.condition,
				e.capacity_m3h * 0.25 * e.severity,
				e.incident_pressure_penalty if e.owning_incident != "" else 0.12 * e.severity,
				e.owning_incident if e.owning_incident != "" else "—",
				str(job.get("job_id", "NONE")),
				("%.0f" % float(job["work_remaining_min"])) if job.has("work_remaining_min") else "—",
				str(job.get("assigned_vehicle", "—")) if job.has("assigned_vehicle") else "—"])
	print("auto_dispatch_water=%s  external_main_breaks=%s  water repair jobs open=%d"
			% [sim.water.auto_dispatch_water, sim.water.external_main_breaks,
			sim.water.repairs.jobs.size()])
	# Doc 06 owns the break once `external_main_breaks` latches, so the crew that
	# is (or is not) coming is ITS incident, not doc 05's job table.
	if sim.incidents == null:
		return
	print("| doc-06 incident | type | tier | status | wait min | assigned | unreachable |")
	for raw: Variant in sim.incidents.snapshot():
		var row: Dictionary = raw
		if String(row["type"]) != "water_main_break":
			continue
		print("| %d | %s | %d | %s | %.0f | %s | %s |"
				% [row["id"], row["type"], row["tier"], row["status"],
				row["wait_min"], str(row["assigned"]), row["unreachable"]])


## **What the player would have to buy, and for how much.** Three lists, in the
## order a player would work them: the repairs the city already owes (doc 05
## §2.12, priced by doc 03 §2.5), the rung under the stage that BINDS
## (§2.5, priced by doc 03 §2.3), and the mains that would move a tile factor
## §2.3 puts under doc 02's upgrade gate. Every figure is the owning command's
## own `preview = true`, so nothing here is a second price table.
func _print_shop(sim: CitySim) -> void:
	print("")
	print("-- the shopping list --")
	var total := 0
	print("  repairs the city owes (cmd_repair_water_asset):")
	var repairs := 0
	for raw: Variant in _sorted_keys(sim.water.edges):
		var edge: WaterEdge = sim.water.edges[raw]
		if edge.state == &"ok":
			continue
		var quote: Dictionary = sim.cmd_repair_water_asset(String(raw), true)
		var payload: Dictionary = quote.get("payload", {})
		print("    %-14s %-8s dmg %.2f  capital $%s  -> $%s  crew %.1f h  stops a %.1f m³/h leak  %s"
				% [raw, edge.state, float(payload.get("damage_fraction", 0.0)),
				_money(int(payload.get("capital", 0))), _money(int(payload.get("cost", 0))),
				float(payload.get("crew_hours", 0.0)), float(payload.get("leak_m3h", 0.0)),
				"OK" if bool(quote["ok"]) else String(quote.get("reason_code", ""))])
		if bool(quote["ok"]):
			total += int(payload.get("cost", 0))
			repairs += 1
	for raw: Variant in _sorted_keys(sim.water.nodes):
		var node: WaterNode = sim.water.nodes[raw]
		if node.variant == &"junction" or node.is_live():
			continue
		var quote2: Dictionary = sim.cmd_repair_water_asset(String(raw), true)
		var payload2: Dictionary = quote2.get("payload", {})
		print("    %-14s %-8s dmg %.2f  -> $%s  %s"
				% [raw, node.state, float(payload2.get("damage_fraction", 0.0)),
				_money(int(payload2.get("cost", 0))),
				"OK" if bool(quote2["ok"]) else String(quote2.get("reason_code", ""))])
		if bool(quote2["ok"]):
			total += int(payload2.get("cost", 0))
			repairs += 1
	if repairs == 0:
		print("    (nothing broken)")
	print("  the rung under the stage that binds (cmd_upgrade_water_component):")
	for raw: Variant in sim.water.supply_chains():
		var chain: Dictionary = raw
		if not bool(chain["live"]):
			continue
		var stage := String(chain["binding"])
		var ids: Array = chain["binding_ids"]
		if stage == "mains":
			print("    %s: BINDS on the mains at %.1f m³/h — a node upgrade buys nothing here; lay a trunk main at the plant (cmd_place_water_main, $%s/tile)"
					% [chain["zone_key"], chain["mains_m3h"],
					_money(sim.econ_curves.water_main_cost_per_tile("trunk",
							float(sim.treasury.difficulty().get("M_build", 1.0))))])
			continue
		if ids.is_empty():
			print("    %s: BINDS on %s and the zone has none — place one (cmd_place_water_component)"
					% [chain["zone_key"], stage])
			continue
		var node_id := String(ids[0])
		var quote3: Dictionary = sim.cmd_upgrade_water_component(node_id, true)
		var payload3: Dictionary = quote3.get("payload", {})
		print("    %s: BINDS on %s at %.1f m³/h -> raise %s to L%d for $%s (+%.0f kW)  %s"
				% [chain["zone_key"], stage, float(chain["binding_m3h"]), node_id,
				int(payload3.get("to_level", 0)), _money(int(payload3.get("cost", 0))),
				float(payload3.get("delta_kw", 0.0)),
				"OK" if bool(quote3["ok"]) else String(quote3.get("reason_code", ""))])
		if bool(quote3["ok"]):
			total += int(payload3.get("cost", 0))
		# What would bind AFTER it — the sentence a player needs before spending.
		print("        (and then %s binds at %.1f m³/h)"
				% [chain["next_binding"], float(chain["next_binding_m3h"])])
	print("  = $%s against a treasury of $%s" % [_money(total), _money(sim.treasury.balance)])


## Buy the repair list, then run the crews out. The acceptance test for a fix is
## the city AFTER the money is spent, not the quote.
func _buy_the_list(sim: CitySim) -> void:
	print("")
	print("-- buying the repairs --")
	var spent := 0
	for raw: Variant in _sorted_keys(sim.water.edges):
		if (sim.water.edges[raw] as WaterEdge).state == &"ok":
			continue
		var result: Dictionary = sim.cmd_repair_water_asset(String(raw), false)
		var payload: Dictionary = result.get("payload", {})
		print("    %s -> %s  $%s  job %s" % [raw,
				"ok" if bool(result["ok"]) else String(result.get("reason_code", "")),
				_money(int(payload.get("cost", 0))), str(payload.get("job_id", "—"))])
		if bool(result["ok"]):
			spent += int(payload.get("cost", 0))
	print("    spent $%s" % _money(spent))
	# Run the crews. Doc 02's queue burns crew-hours on the coarse path like
	# anything else, so this is just city time passing.
	for _i in 4:
		sim.advance_coarse_hours(HOURS_PER_DAY, false)
		sim.bus.drain()


# ======================================================================
# STEP ONE — the player's first sentence, driven end to end
# ======================================================================
#
# *"we need to be able to, one, create a water source; two, put pumps on it."*
#
# The verifier's finding, on this same save: the card enters, and there is no
# legal tile within forty tiles of the plant. `E_NOT_OWNED ×2140`,
# `E_FOOTPRINT ×1092`, `E_NO_WATER ×486` — every refusal correct, every one of
# them invisible, because a ghost answers one tile and the question is a set.
#
# This arm drives the whole of step one and step two **through the shipped UI
# models only** — `BuildController` for the cards and the window read,
# `PathTool` for the run of pipe, `CitySim`'s own commands underneath both — and
# prints every move, every refusal and every dollar. It is the acceptance test
# for the fix: a player who can read this transcript can follow it with a thumb.
func _run_step_one(saves: String, slot: int) -> void:
	_isolate_user_dir()
	if _copy_saves(saves) == 0:
		printerr("measure_water_chain: nothing copied out of " + saves)
		_sweep()
		return
	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	root.add_child(service)
	if not service.load_slot(sim, slot):
		printerr("measure_water_chain: slot %d did not load" % slot)
		root.remove_child(service)
		service.free()
		sim.dispose()
		_sweep()
		return
	var misalign := sim.clock.tick_index % GameClock.TICKS_PER_HOUR
	if misalign != 0:
		sim.scheduler.advance_fine_n(GameClock.TICKS_PER_HOUR - misalign)
	sim.bus.drain()

	print("")
	print("=== STEP ONE on the player's own save, slot %d ===" % slot)
	print("population %d  treasury $%s  buildings %d  water nodes %d  mains %d"
			% [int(sim.population.city_population), _money(sim.treasury.balance),
			sim.buildings.size(), _facility_count(sim), sim.water.edges.size()])
	print("austerity_active=%s  (doc 03 §2.10 layer 2 blocks every `construction` spend while true)"
			% str(sim.treasury.austerity_active))
	_print_chain(sim, 0, false)

	var cfg := UIConfig.load_from_files()
	var formatter := RequirementFormatter.new(cfg)
	var controller := BuildController.new(sim, formatter)
	var opened := sim.treasury.balance
	var placed: Array[String] = []
	# The window is centred where the player's finger is. Step one has no finger
	# yet, so it starts at the city's own water works; steps two and three start
	# at the thing step one just built, because *"put pumps on IT"* is the
	# player's own sentence and a chain is built beside itself.
	var centre := controller._site_home()
	for kind: String in ["source", "treatment", "pump"]:
		var at := _step_one_place(sim, controller, cfg, kind, centre, placed)
		if not TileGrid.in_bounds(at.x, at.y):
			print("    !! could not site a %s — stopping here" % kind)
			break
		centre = at
	print("")
	print("-- what step one cost --")
	print("    treasury $%s -> $%s  (spent $%s)"
			% [_money(opened), _money(sim.treasury.balance),
			_money(opened - sim.treasury.balance)])
	print("    placed: %s" % ("nothing" if placed.is_empty() else ", ".join(placed)))
	# Let the shells finish building. A doc-05 node is born `offline_manual` and
	# goes live when the doc-02 construction job completes, so the chain worth
	# printing is the one after the last crew has left — which is measured, not
	# guessed at, because that wait is itself part of the answer to "how long
	# does step one take".
	# The events that decide whether a site the player paid for ever becomes a
	# node — a fire inside the build window is the whole of A91-D-152 — printed
	# rather than summarised, because "the pump is dark" is not a diagnosis.
	var day := 0
	var news: Array[String] = []
	while day < 30 and _offline_water_nodes(sim) > 0:
		sim.advance_coarse_hours(HOURS_PER_DAY, false)
		for ev: Variant in sim.bus.drain():
			var row: Dictionary = ev
			var kind := String(row.get("type", ""))
			if kind.contains("fire") or kind.contains("damag") or kind.contains("ignit") \
					or kind.contains("burn") or kind.contains("commission"):
				news.append("day %d  %s" % [day + 1, str(row).substr(0, 160)])
		day += 1
	for line: String in news:
		print("    %s" % line)
	for raw: Variant in _sorted_keys(sim.water.nodes):
		var n: WaterNode = sim.water.nodes[raw]
		if n.variant == &"junction" or n.state != &"offline_manual":
			continue
		var shell: Building = sim.buildings.get(n.power_ref)
		print("    !! %s IS STILL OFFLINE: its shell %s is %s at level %d, condition %.2f"
				% [raw, n.power_ref, "gone" if shell == null else String(shell.state),
				0 if shell == null else shell.level,
				0.0 if shell == null else shell.condition])
	print("=== the chain %d game-days later, with the new nodes running ===" % day)
	_print_nodes(sim)
	_print_chain(sim, day, false)
	# A settled week: doc 05 §2.6's restart lockout has expired, doc 04's load
	# has re-solved around the new kW, and the tank has found its level. This is
	# the reading the player would take on the following Monday.
	for _w in 7:
		sim.advance_coarse_hours(HOURS_PER_DAY, false)
		sim.bus.drain()
	print("")
	print("=== a week after that ===")
	_print_chain(sim, day + 7, false)
	# Doc 04's half of the answer (A91-D-153): a pump that is commissioned and
	# `ok` and drawing nothing is a pump on a full pole-top, and `power_fraction`
	# is the only place that shows.
	for raw3: Variant in _sorted_keys(sim.water.nodes):
		var n3: WaterNode = sim.water.nodes[raw3]
		if n3.variant != &"pump":
			continue
		print("    %s: state=%s  power_fraction=%.2f  condition=%.2f  flow=%.1f"
				% [raw3, String(n3.state), sim.water.power_fraction_of(n3),
				n3.condition, n3.flow_m3h])
	root.remove_child(service)
	service.free()
	sim.dispose()
	_sweep()


## One component, sited by following the window's own advice until it can be
## placed. Every loop iteration prints exactly what a player would read on the
## placement bar and exactly what they would tap next.
func _step_one_place(sim: CitySim, controller: BuildController, cfg: UIConfig,
		kind: String, start: Vector2i, placed: Array[String]) -> Vector2i:
	print("")
	print("-- STEP: place a %s --" % kind)
	var entered := controller.enter_water_component(kind)
	print("    BuildController.enter_water_component(%s) -> %s" % [kind,
			"ok" if bool(entered["ok"]) else String(entered.get("reason_code", ""))])
	if not bool(entered["ok"]):
		return Vector2i(-1, -1)
	var centre := start
	for _attempt in 8:
		var hint := controller.placement_sites(centre)
		var advice: Dictionary = hint["advice"]
		print("    window r=%d at (%d, %d): %d legal (%d with power to spare) of %d scanned  %s"
				% [int(hint["radius"]), centre.x, centre.y, int(hint["count"]),
				int(hint["clean"]), int(hint["scanned"]),
				_reason_histogram(hint["reasons"])])
		print("      bar says: %s" % _resolve_advice(cfg, advice))
		if bool(hint["ok"]):
			var tile: Vector2i = hint["nearest"]
			controller.move_to_tile(tile)
			var verdict := controller.verdict()
			var confirm := controller.confirm()
			print("      ghost at (%d, %d) -> %s, can_confirm=%s"
					% [tile.x, tile.y, str(verdict.get("verdict", "")),
					str(controller.can_confirm())])
			if not bool(confirm["ok"]):
				print("      !! confirm refused %s" % String(confirm.get("reason_code", "")))
				return Vector2i(-1, -1)
			var result := sim.cmd_place_water_component(kind, tile,
					controller.component_level, false)
			print("      cmd_place_water_component -> %s  $%s" % [
					"ok" if bool(result["ok"]) else String(result.get("reason_code", "")),
					_money(int((result.get("payload", {}) as Dictionary).get("cost", 0)))])
			controller.cancel()
			if not bool(result["ok"]):
				return Vector2i(-1, -1)
			var shell_now: Building = sim.buildings.get(str((result.get("payload", {}) as Dictionary).get("sim_id", "")))
			print("      shell %s state=%s cond=%.2f job=%s" % [
					str((result.get("payload", {}) as Dictionary).get("sim_id", "")),
					"—" if shell_now == null else String(shell_now.state),
					-1.0 if shell_now == null else shell_now.condition,
					str((result.get("payload", {}) as Dictionary).get("job_id", -1))])
			placed.append("%s at (%d, %d) for $%s" % [kind, tile.x, tile.y,
					_money(int((result.get("payload", {}) as Dictionary).get("cost", 0)))])
			return tile
		if not _step_one_follow(sim, controller, hint, kind):
			return Vector2i(-1, -1)
		# A shoreline answer moves the WINDOW rather than buying anything — and
		# a window that does not move is an answer that has run out, not a loop
		# to keep running.
		var moved: Dictionary = (advice.get("fix_target", {}) as Dictionary).get(
				"params", {}) as Dictionary
		if str(advice.get("key", "")) == "ui_site_no_shoreline":
			if not moved.has("tile") or Vector2i(moved["tile"]) == centre:
				print("      !! the window is already on the water and still has no site")
				return Vector2i(-1, -1)
			centre = moved["tile"]
	return Vector2i(-1, -1)


## Do what the bar's `FIX THIS →` would do. Returns false when the advice is not
## something a player can act on from here.
func _step_one_follow(sim: CitySim, controller: BuildController,
		hint: Dictionary, kind: String) -> bool:
	var advice: Dictionary = hint["advice"]
	match str(advice.get("key", "")):
		"ui_site_buy_block":
			var block_id := str((advice["args"] as Dictionary).get("at", ""))
			var bought := sim.cmd_buy_block(block_id, false)
			print("      -> BUY %s: %s  $%s" % [block_id,
					"ok" if bool(bought["ok"]) else String(bought.get("reason_code", "")),
					_money(int((bought.get("payload", {}) as Dictionary).get("price", 0)))])
			if not bool(bought["ok"]):
				return false
			return _step_one_wait_ready(sim, block_id)
		"ui_site_develop_block":
			var block_id := str((advice["args"] as Dictionary).get("at", ""))
			var started := sim.cmd_start_development(block_id, false)
			print("      -> DEVELOP %s: %s" % [block_id,
					"ok" if bool(started["ok"]) else String(started.get("reason_code", ""))])
			if not bool(started["ok"]):
				return false
			return _step_one_wait_ready(sim, block_id)
		"ui_site_austerity":
			# Doc 03 §2.10 layer 2. The site is READY; the freeze is not. One
			# hour of ordinary play is the whole remedy, and it is the remedy the
			# bar names — this is that hour.
			print("      -> spending frozen (austerity): let one game-hour settle")
			sim.advance_coarse_hours(1, false)
			sim.bus.drain()
			print("         austerity_active=%s" % str(sim.treasury.austerity_active))
			return not sim.treasury.austerity_active
		"ui_site_no_shoreline":
			print("      -> move the window to the water and look again")
			return true
		"ui_site_no_main":
			return _step_one_lay_main(sim, controller, hint, kind)
	return false


## Doc 09's six phases, run by letting city time pass — the same thing a player
## does by putting the phone down. Capped, so a block that will never finish
## reports rather than hangs.
func _step_one_wait_ready(sim: CitySim, block_id: String) -> bool:
	for day in 40:
		var block: LandBlock = sim.world.block(block_id)
		if block != null and block.is_ready():
			print("      -> %s READY after %d game-days" % [block_id, day])
			return true
		sim.advance_coarse_hours(HOURS_PER_DAY, false)
		sim.bus.drain()
	print("      !! %s never reached READY" % block_id)
	return false


## The run of pipe, through `PathTool` — the Utility tab's own card, the same
## door doc 92 §69.5 records as already existing.
func _step_one_lay_main(sim: CitySim, controller: BuildController,
		hint: Dictionary, _kind: String) -> bool:
	var target: Vector2i = hint["centre"]
	var near := sim.water.nearest_main_tile(target, TileGrid.SIZE)
	if near.is_empty():
		print("      !! no live main anywhere to run from")
		return false
	var path := PathTool.new(sim, controller.formatter)
	var entered := path.enter("water_main_service")
	if not bool(entered["ok"]):
		print("      !! PathTool.enter(water_main_service) -> %s"
				% String(entered.get("reason_code", "")))
		return false
	path.move_to_tile(near["tap_tile"])
	path.begin_run(near["tap_tile"])
	path.move_to_tile(target)
	var verdict := path.verdict()
	print("      -> MAIN from (%d, %d) to (%d, %d): %d tiles, %s, $%s"
			% [int(near["tap_tile"].x), int(near["tap_tile"].y), target.x, target.y,
			path.tiles().size(), str(verdict.get("verdict", "")),
			_money(path.run_cost())])
	if not path.can_confirm():
		print("      !! run refused %s" % str(verdict.get("code", "")))
		return false
	var result := path.commit()
	print("      cmd_place_water_main -> %s" % ("ok" if bool(result["ok"])
			else String(result.get("reason_code", ""))))
	return bool(result["ok"])


## Doc 05 §6: a node is born `offline_manual` and is switched on by the doc-02
## construction job that builds its shell. Counting them is how this arm knows
## the crews have finished rather than assuming a number of days.
static func _offline_water_nodes(sim: CitySim) -> int:
	var count := 0
	for raw: Variant in sim.water.nodes:
		var node: WaterNode = sim.water.nodes[raw]
		if node.variant != &"junction" and node.state == &"offline_manual":
			count += 1
	return count


## The window's refusal histogram, biggest first — the read the player never had.
static func _reason_histogram(reasons: Dictionary) -> String:
	var rows: Array = []
	for key: Variant in reasons:
		rows.append([-int(reasons[key]), String(key)])
	rows.sort()
	var parts: Array[String] = []
	for row: Variant in rows:
		parts.append("%s×%d" % [(row as Array)[1], -int((row as Array)[0])])
	return "" if parts.is_empty() else "(" + "  ".join(parts) + ")"


## The advice sentence exactly as `ui/build_sheet.gd` renders it — string key
## through the real table, nested `ui_` args resolved, nothing invented here.
static func _resolve_advice(cfg: UIConfig, advice: Dictionary) -> String:
	var key := str(advice.get("key", ""))
	if key == "" or cfg == null or not cfg.has_string(key):
		return "(no advice)"
	var args: Dictionary = {}
	for arg: Variant in (advice.get("args", {}) as Dictionary):
		var value: Variant = (advice["args"] as Dictionary)[arg]
		args[arg] = cfg.t(str(value)) if str(value).begins_with("ui_") \
				and cfg.has_string(str(value)) else value
	return cfg.t(key, args)


# ---------------------------------------------------------------- utilities

func _facility_count(sim: CitySim) -> int:
	var count := 0
	for raw: Variant in sim.water.nodes:
		if (sim.water.nodes[raw] as WaterNode).variant != &"junction":
			count += 1
	return count


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys


static func _money(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if amount < 0 else "") + digits + out


# ------------------------------------------------------------ private user://

func _isolate_user_dir() -> void:
	var root_dir := OS.get_temp_dir().path_join("slacum-waterchain")
	DirAccess.make_dir_recursive_absolute(root_dir)
	OS.set_environment("XDG_DATA_HOME", root_dir)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
			DIR_MARK + str(OS.get_process_id()))
	_user_dir = OS.get_user_data_dir()
	_remove_tree(_user_dir)
	DirAccess.make_dir_recursive_absolute(_user_dir)


func _copy_saves(source: String) -> int:
	var dest := _user_dir.path_join("saves")
	DirAccess.make_dir_recursive_absolute(dest)
	return _copy_tree(source, dest)


func _copy_tree(source: String, dest: String) -> int:
	var dir := DirAccess.open(source)
	if dir == null:
		return 0
	var copied := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var from := source.path_join(entry)
		var to := dest.path_join(entry)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(to)
			copied += _copy_tree(from, to)
		elif DirAccess.copy_absolute(from, to) == OK:
			copied += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return copied


func _sweep() -> void:
	_remove_tree(_user_dir)


## Recursive delete with the one guard that matters: a path this tool did not
## name is left alone, so a bug here can never take a real `user://` with it.
func _remove_tree(path: String) -> void:
	if path == "" or not path.contains(DIR_MARK):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
