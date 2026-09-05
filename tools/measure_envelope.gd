extends SceneTree
## **The transformer envelope, measured** (Wave 28, doc 93 §BC, doc 92 §68).
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_envelope.gd
##   … -- --table          only §68.1's roster table
##   … -- --panel          only §68.3's data-centre walk
##
## Two instruments, both read-only:
##
## **`--table`** prints, for every archetype at every level, the base kW doc 02
## publishes, the load that becomes at that archetype's own doc 01 channel peak,
## and the transformer rung doc 04 §5.3 needs for it — `X` when no rung on the
## ladder carries it, which is doc 93 §BC-1's wall. Run it on a fork to see the
## nine cells that had no transformer; run it here to see none.
##
## **`--panel`** walks a `data_center` through every rung of its own ladder on a
## real transformer and prints what the three surfaces SAY: the building panel's
## power row (`TransformerPanelModel.building_row`), S18's customer block
## (`PowerActions.transformer_block`) and the fix router's POWER row
## (`FixRouter.route`). The data centre is synthetic — doc 02 gates the archetype
## at city level 4 and the founding city is level 0, so the walk re-stats a
## standing building rather than waiting 30 game-days for one — and that is
## stated here rather than hidden, because every number below it is real: the
## catalog's own stats row, the grid's own gate, the panel's own model.


const ROSTER := ["house", "apartment", "store", "office", "high_rise", "data_center",
		"police_station", "fire_station", "power_facility", "substation",
		"water_facility", "construction_yard"]

## The building the walk re-stats: `water_facility` WTR-2 sits on T-18 in doc 09's
## founding city, alone, which is the cleanest pad in the game to measure a
## single customer's demand against.
const SUBJECT := "WTR-2"


func _initialize() -> void:
	var isolation := UserDirIsolation.new().begin()
	var args := OS.get_cmdline_user_args()
	var want_table := args.is_empty() or args.has("--table")
	var want_panel := args.is_empty() or args.has("--panel")
	if want_table:
		_table()
	if want_panel:
		if want_table:
			print("")
		_panel_walk()
	isolation.end()
	quit(0)


## §68.1 — the whole roster against the ladder.
func _table() -> void:
	var sim := CitySim.boot_from_files(1337)
	var envelope: Dictionary = (StarterCityLoader.read_json(
			"res://data/building_rules.json").get("service_envelope", {}) as Dictionary)
	var classes: Dictionary = envelope.get("demand_class", {})
	var ladder: Array = PowerGrid.CAPACITY[&"transformer"]
	print("ladder (kW)      : ", ladder)
	print("UPGRADE_MAX_R    : %.2f" % PowerGrid.UPGRADE_MAX_R)
	print("envelope (peak)  : %.0f kW" % PowerGrid.service_ceiling_kw())
	print("rung ceilings    : ", _rung_ceilings(ladder))
	print("")
	print("archetype          class       peak   L: base kW / at peak -> rung")
	var stranded := 0
	for archetype in ROSTER:
		var class_id := String(classes.get(archetype, "none"))
		var channel := String(CitySim.DEMAND_CLASS_CHANNEL.get(StringName(archetype), ""))
		var peak := 1.0 if channel == "" else float(sim.curves.channel_peak(channel)["value"])
		var cells: Array[String] = []
		for level in range(1, sim.catalog.max_level_of(archetype) + 1):
			var base := float(sim.catalog.stats(archetype, level).get("power_demand_kw", 0.0))
			if base <= 0.0:
				cells.append("L%d 0" % level)
				continue
			var rung := PowerGrid.transformer_rung_for(base * peak)
			if rung == 0:
				stranded += 1
			cells.append("L%d %s/%s->%s" % [level, _kw(base), _kw(base * peak),
					str(rung) if rung > 0 else "X"])
		print("%-18s %-11s x%.2f  %s" % [archetype, class_id, peak, "  ".join(cells)])
	# Doc 05's per-variant ladders — the reading the tick actually bills for a
	# water facility (`CitySim._water_kw_by_building`).
	print("")
	var civic := float(sim.curves.channel_peak("power_demand_civic")["value"])
	for pair: Array in [[&"source", "river"], [&"source", "well"], [&"treatment", ""],
			[&"pump", ""], [&"tank", ""], [&"booster", ""]]:
		var cells: Array[String] = []
		for level in range(1, 6):
			var kw := sim.water.data.kw_required(StringName(pair[0]), level, String(pair[1]))
			var rung := PowerGrid.transformer_rung_for(kw * civic)
			if rung == 0:
				stranded += 1
			cells.append("L%d %s/%s->%s" % [level, _kw(kw), _kw(kw * civic),
					str(rung) if rung > 0 else "X"])
		print("%-18s %-11s x%.2f  %s" % ["doc05 " + String(pair[0])
				+ ("_" + String(pair[1]) if String(pair[1]) != "" else ""),
				"civic", civic, "  ".join(cells)])
	print("")
	print("cells with NO transformer rung: %d" % stranded)
	sim.dispose()


## §68.3 — a data centre at every level, and what the three surfaces say.
func _panel_walk() -> void:
	var sim := CitySim.boot_from_files(1337)
	sim.advance_hours(6.0)
	sim.treasury.credit(5_000_000, &"measure_grant")
	var actions := PowerActions.new(sim)
	var host := String(sim.grid.attachment_of(SUBJECT))
	print("subject %s on %s (L%d, %.0f kW) — re-stated as a data_center at each rung"
			% [SUBJECT, host, int(sim.grid.component(host)["level"]),
			float(sim.grid.component(host)["capacity_kw"])])
	print("")
	print("DC level  base kW  next kW   pad kW  host  needs  panel row")
	var b: Building = sim.buildings[SUBJECT]
	var top: int = sim.catalog.max_level_of("data_center")
	for level in range(1, top + 1):
		b.archetype = &"data_center"
		b.level = level
		b.max_level = top
		b.stats = sim.catalog.stats("data_center", level).duplicate()
		sim.advance_hours(1.0)   # one tick, so `load_kw` and the peak table are this level's
		var next: Dictionary = actions.next_level(SUBJECT)
		var row: Dictionary = TransformerPanelModel.building_row(actions, SUBJECT)
		var needs: Dictionary = row.get("needs_upgrade", {})
		var next_kw := 0.0 if level >= top \
				else float(sim.catalog.stats("data_center", level + 1).get("power_demand_kw", 0.0))
		# `pad kW` is `rung_needed`'s own input — the pad's peak plus the delta —
		# so the rung beside it can be checked rather than believed.
		var at_top: bool = not bool(next.get("available", false))
		print("L%-8d %-8s %-9s %-7s %-5s %-6s %s" % [level,
				_kw(float(b.stats.get("power_demand_kw", 0.0))),
				"—" if at_top else _kw(next_kw),
				"—" if at_top else _kw(float(next.get("after_kw", 0.0))),
				"—" if at_top else "L%d" % int(next.get("host_level", 0)),
				"—" if at_top else "L%d" % int(next.get("needs_rung", 0)),
				("%s to=%d rung=%d host=%d kw=%s" % [String(needs.get("text_key", "")),
						int(needs.get("to_level", 0)), int(needs.get("needs_rung", 0)),
						int(needs.get("host_level", 0)),
						String(needs.get("needs_capacity_text", ""))])
						if not needs.is_empty()
						else ("(top of the ladder — no next level to size a pad for)"
								if not bool(next.get("available", false))
								else "(the pad it has carries it)")])
	print("")
	# S18's own line, and the fix router's, at the level the player reported.
	b.level = 2
	b.stats = sim.catalog.stats("data_center", 2).duplicate()
	sim.advance_hours(1.0)
	var block := actions.transformer_block(host)
	print("S18 on %s: customers=%d need_rung=%d need_bigger=%s for=%s cap=%s stranded='%s'"
			% [host, int(block["customer_count"]), int(block["customers_need_rung"]),
			str(block["customers_need_bigger"]), String(block["customers_need_rung_for"]),
			String(block["customers_need_capacity_text"]), String(block["customer_stranded"])])
	var routed := FixRouter.route(sim, {"kind": RequirementFormatter.FIX_POWER,
			"id": host, "sim_id": SUBJECT}, true)
	var quote: Dictionary = (routed.get("quote", {}) as Dictionary).get("payload", {})
	var need: Dictionary = routed.get("needs", {})
	print("router POWER: action=%s to_level=%s cost=%s clears=%s | needs rung %d (%s), host L%d"
			% [String(quote.get("action", String(routed.get("action", "")))),
			str(quote.get("to_level", "—")), str(quote.get("cost", "—")),
			str(quote.get("clears", "—")), int(need.get("needs_rung", 0)),
			_kw(float(need.get("needs_capacity_kw", 0.0))), int(need.get("host_level", 0))])
	sim.dispose()


func _rung_ceilings(ladder: Array) -> Array:
	var out: Array[float] = []
	for c: Variant in ladder:
		out.append(PowerGrid.UPGRADE_MAX_R * float(c))
	return out


func _kw(value: float) -> String:
	return "%.0f" % value if value >= 10.0 else "%.1f" % value
