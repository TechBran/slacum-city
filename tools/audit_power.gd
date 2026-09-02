extends SceneTree
## The doc 04 model audit, as a runnable measurement (doc 92 §48.1 / doc 93 §AD1).
##
##     godot --headless --script tools/audit_power.gd -- [--city=PATH] [--play=DAYS]
##                                                       [--seed=N] [--hours=H]
##
## Boots a city (the starter city by default, `--city=res://tests/fixtures/
## bench_city.json` for the benchmark), optionally plays doc 92's `balanced`
## strategy for `--play` game-days on the online coarse path so the census runs
## on a PLAYED city rather than an authored one, advances `--hours` fine hours,
## and then answers the five questions the audit asks, each as a number:
##
##   (i)   place a power station: does `system_supply_kw` rise by its
##         `capacity_kw`, and how many POWER_CAPACITY blockers does it clear?
##   (ii)  where is every POWER_CAPACITY blocker actually bound — transformer,
##         feeder or substation?
##   (iii) route a feeder to a blocked building's transformer: does the quote
##         adopt that transformer, and does the blocker clear next hour?
##   (iv)  is anything shed, and what would shed first if the pool fell short?
##   (v)   the silent limits: service radius, tap radius, slots, classes.
##
## Read-only except for the commands it names; it writes nothing.

const STARTER_CITY := "res://data/starter_city.json"
const Playtest := preload("res://tools/playtest.gd")

var city_path := STARTER_CITY
var play_days := 0
var seed_value := 1337
var hours := 6.0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--city="):
			city_path = text.trim_prefix("--city=")
		elif text.begins_with("--play="):
			play_days = int(text.trim_prefix("--play="))
		elif text.begins_with("--seed="):
			seed_value = int(text.trim_prefix("--seed="))
		elif text.begins_with("--hours="):
			hours = float(text.trim_prefix("--hours="))
	var sim := _boot()
	if play_days > 0:
		_play(sim, play_days)
	sim.advance_hours(hours)
	print("audit_power: city=%s seed=%d play_days=%d fine_hours=%.1f buildings=%d"
			% [city_path, seed_value, play_days, hours, sim.buildings.size()])
	_grid_summary(sim)
	var census := _blocker_census(sim)
	_probe_feeder(sim, census)
	_probe_fix(sim, census)
	_probe_plant(sim)
	_probe_shedding(sim)
	_probe_limits(sim)
	sim.dispose()
	_probe_outage_cost()
	quit(0)


func _boot() -> CitySim:
	if city_path == STARTER_CITY:
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(city_path),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	for message in sim.boot_errors:
		printerr("  boot: " + String(message))
	return sim


## Doc 92's `balanced` bot on the online coarse step — `BalanceGateRig.run`'s
## loop, without the summary, so the city it leaves behind is the one measured.
func _play(sim: CitySim, days: int) -> void:
	var strategy: RefCounted = Playtest.Factory.make("balanced")
	var api: RefCounted = Playtest.Api.new(sim)
	var events: Dictionary = {}
	sim.bus.drain()
	for h in days * 24:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		var settled: Dictionary = Playtest.Runner._drain(sim, events)
		var sample: Dictionary = Playtest.Runner._sample(sim, h + 1, settled, 0.0)
		if strategy is Playtest.Balanced:
			(strategy as Playtest.Balanced).note_expense(float(sample["expenses"]))
	print("  played %d game-days: balance $%d, buildings %d, feeders %d, substations %d"
			% [days, sim.treasury.balance, sim.buildings.size(),
			sim.grid.component_ids_of_kind(&"feeder").size(),
			sim.grid.component_ids_of_kind(&"substation").size()])


func _ambient(sim: CitySim) -> float:
	return float(sim.weather.env_for_grid().get("t_ambient_c", 25.0))


func _grid_summary(sim: CitySim) -> void:
	var t := _ambient(sim)
	var s := sim.grid.capacity_summary(t)
	print("[grid] supply %.0f kW  demand %.0f kW  headroom %.0f kW  pool r %.3f  shed feeders %d"
			% [s["supply_kw"], s["demand_kw"], s["headroom_kw"], s["load_ratio"], s["shed_feeders"]])
	var wf := sim.grid.worst_feeder(t)
	var wt := sim.grid.worst_transformer(t)
	print("[grid] worst feeder %s r %.3f (%.0f / %.0f kW); worst transformer %s r %.3f (%.0f / %.0f kW)"
			% [wf["id"], wf["load_ratio"], wf["load_kw"], wf["capacity_kw"],
			wt["id"], wt["load_ratio"], wt["load_kw"], wt["capacity_kw"]])
	var bands := {"transformer": [0, 0, 0, 0], "feeder": [0, 0, 0, 0]}
	for id in sim.grid.component_ids():
		var c: Dictionary = sim.grid.component(String(id))
		var kind := String(c["kind"])
		if not bands.has(kind):
			continue
		var r: float = float(c["load_kw"]) / maxf(1.0, sim.grid.cap_eff(String(id), t))
		var slot := 0 if r < 0.75 else (1 if r < 0.90 else (2 if r < 1.05 else 3))
		bands[kind][slot] += 1
	for kind in ["transformer", "feeder"]:
		print("[grid] %-11s r<0.75: %d  0.75-0.90: %d  0.90-1.05: %d  >1.05: %d"
				% [kind, bands[kind][0], bands[kind][1], bands[kind][2], bands[kind][3]])
	var plants := sim.grid.component_ids_of_kind(&"plant_gas")
	var subs := sim.grid.component_ids_of_kind(&"substation")
	var slot_text: Array = []
	for sub in subs:
		var slots := sim.grid.feeder_slots(String(sub))
		slot_text.append("%s L%d %d/%d" % [sub, int(sim.grid.component(String(sub))["level"]),
				int(slots["used"]), int(slots["total"])])
	print("[grid] plants %d %s; substations %d [%s]" % [plants.size(), str(plants),
			subs.size(), ", ".join(PackedStringArray(slot_text))])


## Every building's upgrade gate, and for each POWER_CAPACITY blocker the
## component that actually binds — the answer the checklist row cannot give.
func _blocker_census(sim: CitySim) -> Dictionary:
	var t := _ambient(sim)
	var blocked: Array = []
	var by_kind := {"transformer": 0, "feeder": 0, "substation": 0, "UNSERVED": 0}
	var previews := 0
	for sim_id in sim.roster_ids():
		var preview := sim.cmd_upgrade_building(String(sim_id), true)
		var blockers: Array = (preview.get("payload", {}) as Dictionary).get("blockers", [])
		previews += 1
		if not blockers.has(&"E_POWER_HEADROOM"):
			continue
		var b: Building = sim.buildings[sim_id]
		var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
		var delta := (float(next_stats.get("power_demand_kw", 0.0))
				- float(b.stats.get("power_demand_kw", 0.0))) * CitySim.UPGRADE_HEADROOM_MARGIN
		var bind := _binding_component(sim, String(sim_id), delta, t)
		var kind := String(bind["kind"])
		if kind == "":
			# The gate refused on something the serving-path walk does not name.
			# Counted under its own head, never silently dropped.
			kind = "UNSERVED"
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
		blocked.append({"sim_id": String(sim_id), "bind": bind, "delta_kw": delta,
				"level": b.level, "archetype": String(b.archetype)})
	print("[census] %d upgrade previews, %d blocked on POWER_CAPACITY: transformer-bound %d, feeder-bound %d, substation-bound %d, unserved %d"
			% [previews, blocked.size(), by_kind["transformer"], by_kind["feeder"],
			by_kind["substation"], by_kind["UNSERVED"]])
	for i in mini(5, blocked.size()):
		var row: Dictionary = blocked[i]
		var bind: Dictionary = row["bind"]
		print("  %s (%s L%d, +%.1f kW) binds at %s %s r_after %.3f"
				% [row["sim_id"], row["archetype"], row["level"], row["delta_kw"],
				bind["kind"], bind["id"], bind["r_after"]])
	return {"blocked": blocked, "by_kind": by_kind}


## The binding component, ASKED rather than re-derived: `CitySim.power_headroom`
## runs `can_upgrade_power` with the peak-load override and names the component
## whose post-upgrade ratio is worst past doc 04 §5.3's ceiling. This used to be
## a second copy of that walk against the LIVE load, and the copy went blind the
## moment the gate started reading the peak (Wave 17).
func _binding_component(sim: CitySim, sim_id: String, delta_kw: float,
		_t: float) -> Dictionary:
	var headroom := sim.power_headroom(sim_id, delta_kw)
	if String(headroom["reason"]) == "UNSERVED":
		return {"kind": "UNSERVED", "id": "", "r_after": 0.0}
	if bool(headroom["ok"]):
		return {"kind": "", "id": "", "r_after": float(headroom.get("r_after", 0.0))}
	return {"kind": String(headroom["kind"]), "id": String(headroom["at"]),
			"r_after": float(headroom["r_after"])}


## (iii) The one-tap feeder on the first FEEDER-bound blocker: quote it, buy it,
## and see whether the blocker clears within the hour.
func _probe_feeder(sim: CitySim, census: Dictionary) -> void:
	var target := {}
	for row in (census["blocked"] as Array):
		if String((row["bind"] as Dictionary)["kind"]) == "feeder":
			target = row
			break
	if target.is_empty():
		print("[feeder] no feeder-bound blocker in this city; nothing to route")
		return
	var sim_id := String(target["sim_id"])
	var transformer_id := sim.grid.attachment_of(sim_id)
	var tile: Vector2i = sim.grid.component_tile(transformer_id)
	sim.treasury.credit(1_000_000, &"audit_grant")
	var quote := sim.cmd_place_grid_component("feeder", tile, 2, true)
	print("[feeder] one-tap quote to %s at %s: ok=%s reason=%s cost=%s adopts=%s adopted_kw=%s slots_free=%s substation=%s"
			% [transformer_id, tile, quote["ok"], quote.get("reason_code", ""),
			quote.get("payload", {}).get("cost", "-"), quote.get("payload", {}).get("adopts", "-"),
			quote.get("payload", {}).get("adopted_kw", "-"),
			quote.get("payload", {}).get("feeder_slots_free", "-"),
			quote.get("payload", {}).get("substation", "-")])
	if not bool(quote["ok"]):
		return
	var routed := sim.cmd_place_grid_component("feeder", tile, 2)
	var adopted: Array = routed["payload"].get("adopted", [])
	print("[feeder] routed %s: adopted %s (target transformer adopted: %s)"
			% [routed["payload"].get("component", ""), str(adopted), adopted.has(transformer_id)])
	sim.advance_hours(1.0)
	var after := sim.cmd_upgrade_building(sim_id, true)
	var blockers: Array = (after.get("payload", {}) as Dictionary).get("blockers", [])
	print("[feeder] one hour later, %s upgrade blockers: %s -> POWER_CAPACITY cleared: %s"
			% [sim_id, str(blockers), not blockers.has(&"E_POWER_HEADROOM")])


## (i) A second (or third) power station: the bulk pool grows by exactly the
## plant's rating and the count of POWER_CAPACITY blockers it clears is printed
## beside it.
func _probe_plant(sim: CitySim) -> void:
	sim.treasury.credit(2_000_000, &"audit_grant")
	var before_census := _blocker_count(sim)
	var supply_before := sim.grid.system_supply_kw
	var origin := Vector2i(-1, -1)
	for z in range(0, TileGrid.SIZE - 3):
		for x in range(0, TileGrid.SIZE - 3):
			var candidate := Vector2i(x, z)
			var block := sim.world.block_of_tile(x, z)
			if block == null or not block.is_owned() or not block.is_ready():
				continue
			if sim.world.grid.can_place(candidate, Vector2i(3, 3)) and sim.grid.would_serve(candidate):
				origin = candidate
				break
		if origin.x >= 0:
			break
	if origin.x < 0:
		print("[plant] no 3x3 site; skipped")
		return
	var placed := sim.cmd_place_building("power_facility", origin)
	if not bool(placed["ok"]):
		print("[plant] placement refused: %s" % placed["reason_code"])
		return
	var sim_id := String(placed["payload"]["sim_id"])
	for i in 40:
		if (sim.buildings[sim_id] as Building).state != &"under_construction":
			break
		sim.advance_hours(4.0)
	sim.advance_hours(1.0)
	var supply_after := sim.grid.system_supply_kw
	print("[plant] %s at %s: supply %.0f -> %.0f kW (+%.0f, plant_gas L1 rates %.0f); POWER_CAPACITY blockers %d -> %d"
			% [sim_id, origin, supply_before, supply_after, supply_after - supply_before,
			PowerGrid.CAPACITY[&"plant_gas"][0], before_census, _blocker_count(sim)])


func _blocker_count(sim: CitySim) -> int:
	var n := 0
	for sim_id in sim.roster_ids():
		var preview := sim.cmd_upgrade_building(String(sim_id), true)
		if ((preview.get("payload", {}) as Dictionary).get("blockers", []) as Array).has(&"E_POWER_HEADROOM"):
			n += 1
	return n


## (iii, Wave 17) The one-tap fix on every blocked building: what the planner
## quotes, and — bought on the first one — whether the blocker clears.
func _probe_fix(sim: CitySim, census: Dictionary) -> void:
	var blocked: Array = census["blocked"]
	if blocked.is_empty():
		print("[fix] nothing blocked; nothing to plan")
		return
	var actions: Dictionary = {}
	var total_cost := 0
	for row in blocked:
		var quote := sim.cmd_fix_power_capacity(String(row["sim_id"]), true)
		var payload: Dictionary = quote.get("payload", {})
		var key := String(payload.get("action", "")) if bool(quote["ok"]) \
				else "refused:" + String(quote.get("reason_code", ""))
		actions[key] = int(actions.get(key, 0)) + 1
		if bool(quote["ok"]):
			total_cost += int(payload.get("cost", 0))
	print("[fix] %d blocked buildings plan as %s; total quoted $%d" % [blocked.size(), str(actions), total_cost])
	var first := String((blocked[0] as Dictionary)["sim_id"])
	var quote := sim.cmd_fix_power_capacity(first, true)
	if not bool(quote["ok"]):
		print("[fix] %s refused: %s %s" % [first, quote["reason_code"], str(quote.get("payload", {}))])
		return
	var plan: Dictionary = quote["payload"]
	sim.treasury.credit(int(plan["cost"]), &"audit_grant")
	var balance: int = sim.treasury.balance
	var bought := sim.cmd_fix_power_capacity(first)
	var after := sim.cmd_upgrade_building(first, true)
	var blockers: Array = (after.get("payload", {}) as Dictionary).get("blockers", [])
	print("[fix] %s: %s %s -> L%s cost $%d (charged $%d); cleared=%s; upgrade blockers now %s"
			% [first, plan["action"], plan.get("component", ""), str(plan.get("to_level", plan.get("to_class", "-"))),
			int(plan["cost"]), balance - sim.treasury.balance,
			bought.get("payload", {}).get("cleared", false), str(blockers)])


## (iv) Shedding: what would go first if the pool fell short, forced by failing
## the largest plant for one tick and restored afterwards.
func _probe_shedding(sim: CitySim) -> void:
	var plants := sim.grid.component_ids_of_kind(&"plant_gas")
	if plants.size() < 2:
		print("[shed] one plant only: a plant trip is a total blackout, not a shed; the shed order is unit-tested (test_power_grid::test_we4_shedding)")
		return
	var victim := ""
	for id in plants:
		if victim == "" or float(sim.grid.component(String(id))["capacity_kw"]) \
				> float(sim.grid.component(victim)["capacity_kw"]):
			victim = String(id)
	sim.grid.component(victim)["state"] = &"FAILED"
	sim.grid.topology_dirty = true
	sim.advance_hours(0.25)
	var events: Array = []
	for e in sim.bus.drain():
		var kind := String((e as Dictionary).get("type", ""))
		if kind.begins_with("LoadShed") or kind.begins_with("Rolling") or kind == "BlockDarkChanged":
			events.append(kind)
	var s := sim.grid.capacity_summary(_ambient(sim))
	print("[shed] %s failed: supply %.0f demand %.0f -> shed feeders %d holding %.0f kW dark; events %s"
			% [victim, s["supply_kw"], s["demand_kw"], s["shed_feeders"], s["shed_kw"], str(events)])
	sim.grid.repair_component(victim)


## (Wave 17, doc 04 §2.14) What a transformer outage costs: the same city twice
## from the same boot, one of them losing its busiest transformer, one
## game-hour later. Reported as the balance gap net of the refund.
func _probe_outage_cost() -> void:
	var control := _boot()
	var victim_sim := _boot()
	for s in [control, victim_sim]:
		if play_days > 0:
			_play(s, play_days)
		s.advance_hours(hours)
	# The transformer whose loss STRANDS the most buildings (the quote's own
	# count), customers then id as tie-breaks — the worst single outage a
	# demolition can cause in this city.
	var worst := ""
	var worst_key := [-1, -1, ""]
	for id in victim_sim.grid.component_ids_of_kind(&"transformer"):
		var q: Dictionary = victim_sim.cmd_demolish_grid_component(String(id), true).get("payload", {})
		var key := [(q.get("stranded", []) as Array).size(), int(q.get("customers", 0)), String(id)]
		if key[0] > worst_key[0] or (key[0] == worst_key[0] and key[1] > worst_key[1]) \
				or (key[0] == worst_key[0] and key[1] == worst_key[1] and String(id) < String(worst_key[2])):
			worst_key = key
			worst = String(id)
	if worst == "":
		print("[outage] no transformer; skipped")
		return
	var balance_before: int = victim_sim.treasury.balance
	var gone := victim_sim.cmd_demolish_grid_component(worst)
	var payload: Dictionary = gone.get("payload", {})
	var refund := int(payload.get("refund", 0))
	var dark_events := 0
	for e in victim_sim.bus.drain():
		if String((e as Dictionary).get("type", "")) == "BuildingPowerChanged" \
				and String((e as Dictionary).get("state", "")) == "DARK":
			dark_events += 1
	var line := "[outage] demolish %s (L%s, %d customers, %d stranded, refund $%d):" \
			% [worst, str(payload.get("level", "?")), int(payload.get("customers", 0)),
			(payload.get("stranded", []) as Array).size(), refund]
	for hour in 3:
		control.advance_hours(1.0)
		victim_sim.advance_hours(1.0)
		for e in victim_sim.bus.drain():
			if String((e as Dictionary).get("type", "")) == "BuildingPowerChanged" \
					and String((e as Dictionary).get("state", "")) == "DARK":
				dark_events += 1
		var dark := 0
		for building_id in victim_sim.roster_ids():
			if not victim_sim.grid.is_powered(String(building_id)):
				dark += 1
		var control_gain := control.treasury.balance - balance_before
		var victim_gain := victim_sim.treasury.balance - balance_before - refund
		line += " | h+%d: %d DARK, %d DARK events, control +$%d, victim +$%d net of refund, cost $%d" \
				% [hour + 1, dark, dark_events, control_gain, victim_gain, control_gain - victim_gain]
	print(line)
	control.dispose()
	victim_sim.dispose()


## (v) What silently refuses.
func _probe_limits(sim: CitySim) -> void:
	var rules: Dictionary = sim.grid_rules
	var placeable: Dictionary = rules.get("placeable", {}).get("transformer", {})
	var routable: Dictionary = rules.get("routable", {}).get("feeder", {})
	print("[limits] transformer levels %s of %s kW; radius %s; tap %d tiles; feeder classes %s of %s kW; slots per substation level %s"
			% [str(placeable.get("placeable_levels", [])),
			str(PowerGrid.CAPACITY[&"transformer"]),
			str(placeable.get("service_radius_tiles", [])),
			int(placeable.get("feeder_tap_radius_tiles", 0)),
			str(routable.get("conductor_classes", [])), str(PowerGrid.FEEDER_CAPACITY),
			str(PowerGrid.SUBSTATION_FEEDER_SLOTS)])
	var unserved := sim.grid.unserved_building_ids()
	print("[limits] unserved buildings now: %d" % unserved.size())
