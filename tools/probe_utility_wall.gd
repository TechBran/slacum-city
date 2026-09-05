extends SceneTree
## **The utility wall, measured** — the instrument doc 92 §67.1, doc 91
## A91-D-137 and report 98 RR-213 cite for their fork evidence (Wave 26 merge,
## 2026-09-05). Runs the curriculum agent for `--days` on `--seed` (the same
## loop `tests/balance_gate_rig.gd` runs), then, at that day, prints everything
## the level-7 wall is made of: which `upgrade_archetype` rows are open, the
## blocked building and what `blocked_upgrade` says about it, the pool, the
## building's power path hop by hop, its transformer's own upgrade preview, the
## agent's parallel-transformer spot search at two radii, the water zone the
## building drinks from, every supply node's upgrade preview, and the two water
## doors tried live. Then it forces the transformer upgrade and reports whether
## the building clears once the job lands — the player's door, driven.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/probe_utility_wall.gd \
##       -- [--seed=1337] [--days=25] [--archetype=high_rise]
##
## A MEASURING instrument: owns no constant, imports nothing into sim/ game/ ui/.
const Playtest := preload("res://tools/playtest.gd")

func _initialize() -> void:
	var seed_value := 1337
	var days := 25
	var archetype := "high_rise"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_value = int(a.trim_prefix("--seed="))
		elif a.begins_with("--days="):
			days = int(a.trim_prefix("--days="))
		elif a.begins_with("--archetype="):
			archetype = a.trim_prefix("--archetype=")
	var sim := CitySim.boot_from_files(seed_value)
	var strategy = Playtest.Factory.make("curriculum")
	var api = Playtest.Api.new(sim)
	var events := {}
	sim.bus.drain()
	for h in days * 24:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		Playtest.Runner._drain(sim, events)
	print("seed %d day %d: goal level %d city level %d treasury $%d reason_codes %s" % [
			seed_value, days, sim.goals.earned_level, sim.progression.city_level,
			sim.treasury.balance, str(api.reason_codes)])
	for raw in (sim.goals.view().get("objectives", []) as Array):
		var obj: Dictionary = raw
		if not bool(obj.get("done", false)):
			print("  open objective: %s (%s)" % [str(obj.get("id")), str(obj.get("kind"))])
	var blocked: Dictionary = api.blocked_upgrade(archetype)
	print("blocked_upgrade(%s): %s" % [archetype, str(blocked)])
	print("grid.capacity_summary: ", sim.grid.capacity_summary())
	if blocked.is_empty():
		quit()
		return
	var sim_id := String(blocked["sim_id"])
	var b: Building = sim.buildings[sim_id]
	var next: Dictionary = sim.catalog.stats(archetype, b.level + 1)
	var delta_kw := float(next.get("power_demand_kw", 0.0)) - float(b.stats.get("power_demand_kw", 0.0))
	var ph: Dictionary = sim.power_headroom(sim_id, delta_kw * CitySim.UPGRADE_HEADROOM_MARGIN)
	print("power_headroom(%s, %.1f kW): ok=%s at=%s kind=%s r_after=%.3f" % [sim_id,
			delta_kw * CitySim.UPGRADE_HEADROOM_MARGIN, str(ph.get("ok")), str(ph.get("at")),
			str(ph.get("kind")), float(ph.get("r_after", 0.0))])
	for hop in ph.get("path", []):
		print("   hop %-8s %-11s load %.0f peak %.0f eff %.0f r_after %.3f" % [str(hop.get("id")),
				str(hop.get("kind")), float(hop.get("load_kw", 0)), float(hop.get("peak_load_kw", 0)),
				float(hop.get("effective_kw", 0)), float(hop.get("r_after", 0))])
	var at := String(ph.get("at", ""))
	if at != "" and sim.grid.has_component(at):
		var c := sim.grid.component(at)
		print("component %s: kind %s level %d state %s capacity %.0f" % [at, String(c.get("kind", "")),
				int(c.get("level", 0)), String(c.get("state", "")), float(c.get("capacity_kw", 0))])
		print("upgrade preview %s: %s" % [at, str(sim.cmd_upgrade_grid_component(at, true))])
	print("relief spot near %s, radius 3: %s | radius 12: %s" % [str(b.origin),
			str(api.relief_spot_near(b.origin, 3, 3)), str(api.relief_spot_near(b.origin, 3, 12))])
	var tile: Vector2i = sim.water.demand.access_tile(sim_id)
	var z = sim.water.zone_at(tile)
	print("water zone at %s: %s" % [str(tile), "none" if z == null else "supply %.1f demand %.1f headroom %.1f pressure %.2f dead %s" % [
			z.supply_m3h, z.demand_m3h, z.headroom_m3h(), z.pressure, str(z.dead)]])
	var ids: Array = sim.water.nodes.keys()
	ids.sort()
	for id in ids:
		var n = sim.water.nodes[id]
		if String(n.variant) == "junction":
			continue
		var r: Dictionary = sim.cmd_upgrade_water_component(String(id), true)
		print("  water node %-10s %-10s L%d -> %s %s cost %s" % [String(id), String(n.variant), int(n.level),
				"OK" if bool(r.get("ok", false)) else String(r.get("reason_code", "")),
				str((r.get("payload", {}) as Dictionary).get("blockers", "")),
				str((r.get("payload", {}) as Dictionary).get("cost", ""))])
	print("door: place pump -> ", api.place_water_component("pump", 1).get("reason_code", "OK"))
	print("door: upgrade_water_node -> ", api.upgrade_water_node().get("reason_code", "OK"))
	# The player's door, driven: the transformer named by the refusal.
	if at != "" and sim.grid.has_component(at):
		sim.treasury.balance = maxi(sim.treasury.balance, 50_000_000)
		print("forced upgrade of %s -> %s" % [at, str(sim.cmd_upgrade_grid_component(at, false).get("reason_code", "OK"))])
		for h in 72:
			sim.advance_coarse_hours(1, false)
		print("after 72 h: %s level %d; %s preview blockers: %s" % [at,
				int(sim.grid.component(at).get("level", -1)), sim_id,
				str((sim.cmd_upgrade_building(sim_id, true).get("payload", {}) as Dictionary).get("blockers", ""))])
	quit()
