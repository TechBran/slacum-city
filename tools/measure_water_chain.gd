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
	for raw: Variant in sim.water.demand.sorted_ids():
		var building_id := String(raw)
		var tile: Vector2i = sim.water.demand.access_tile(building_id)
		var z: PressureZone = sim.water.zone_at(tile)
		if z == null:
			continue
		if not per_zone.has(z.zone_key):
			per_zone[z.zone_key] = []
		(per_zone[z.zone_key] as Array).append(sim.water.pressure_at(tile))
	var gate := sim.water.data.effect("upgrade_min_pressure", 0.55)
	for key: Variant in _sorted_keys(per_zone):
		var values: Array = per_zone[key]
		values.sort()
		var under := 0
		for value: float in values:
			if value < gate:
				under += 1
		print("  spread %s: n=%d  min %.2f  p25 %.2f  median %.2f  max %.2f  | under the %.2f upgrade gate: %d (%.0f%%)"
				% [key, values.size(), values[0], values[values.size() / 4],
				values[values.size() / 2], values[-1], gate, under,
				100.0 * float(under) / float(values.size())])


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
