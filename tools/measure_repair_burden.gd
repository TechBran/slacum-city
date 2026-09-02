extends SceneTree
## The repair burden, measured per game-day and per ASSET CLASS (doc 92 §43.1).
##
## The 2026-09-01 playtest said three things about repair: it is too
## aggressive, it bills the city for buildings the city does not own, and it
## interrupts play for nothing. Every one of those is a number before it is a
## ruling, and this is the instrument that takes them. It boots the real
## `CitySim`, drives a `tools/playtest.gd` strategy through the real command
## layer on the coarse step (the same rig every doc 92 table is measured on),
## and reports, per game-day:
##
##   * repair DOLLARS by asset class — private buildings (residential,
##     commercial, industrial, tech) against civic/utility buildings, the city's
##     hourly `building_maint` line, and the `roads_repair` accrual;
##   * repair TRIPS by class (`repair_started_sim`), and the condition-band
##     crossings that make a player reach for one: Good→Worn (0.85), Worn→Poor
##     (0.60, doc 02's warning badge), the auto-damage line (0.35) and destroyed;
##   * what reaches a SURFACE — the doc 08 push/alert class each event would be
##     offered to (`data/notifications.json` bindings), the doc 12 event-log row
##     (`data/ui.json.event_log`), and the building-panel REPAIR affordance,
##     which is drawn for any building under condition 1.00;
##   * the share of the day's settled net that repair dollars ate.
##
## `--absence=N` then runs a capped offline catch-up of N game-hours on the
## finished city (doc 01's cap is 720 = one night away) and prints what the
## player wakes up to: bands by class, damaged/destroyed counts, and the
## "morning bill" — the doc 03 §2.5 quote for every building under the
## `balanced` agent's 0.80 repair threshold.
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_repair_burden.gd \
##       -- [--days=21] [--seeds=1337] [--strategies=do_nothing,balanced,curriculum]
##          [--city=starter|bench] [--absence=720] [--bucket=7]
##
## A MEASURING instrument (constitution §3): it owns no balance constant and
## nothing in `sim/` imports it.

const Playtest := preload("res://tools/playtest.gd")

const STARTER_CITY := "res://data/starter_city.json"
const BENCH_CITY := "res://tests/fixtures/bench_city.json"
const HOURS_PER_DAY := 24
const PRIVATE_CLASSES := ["residential", "commercial", "industrial", "tech"]
## The `balanced` agent's own repair threshold (tools/playtest.gd), i.e. what a
## maintaining player fixes at — the morning bill is quoted against it.
const MAINTAINER_THRESHOLD := 0.80
## Doc 02 §2.6's bands, on [0,1]: Good ≥ 0.85, Worn ≥ 0.60, Poor ≥ 0.35, Failing.
const BANDS := [0.85, 0.60, 0.35]

var _bindings: Array = []
var _notify_classes: Dictionary = {}
var _log_rules: Array = []


func _initialize() -> void:
	var days := 21
	var seeds: Array[int] = [1337]
	var strategies: Array[String] = ["do_nothing", "balanced", "curriculum"]
	var city := "starter"
	var absence := 0
	var bucket := 7
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		var split := arg.find("=")
		if split < 0:
			continue
		var key := arg.substr(0, split)
		var value := arg.substr(split + 1)
		match key:
			"--days": days = int(value)
			"--seeds":
				seeds = [] as Array[int]
				for part in value.split(",", false):
					seeds.append(int(part))
			"--strategies":
				strategies = [] as Array[String]
				for part in value.split(",", false):
					strategies.append(String(part))
			"--city": city = value
			"--absence": absence = int(value)
			"--bucket": bucket = maxi(1, int(value))
			_:
				printerr("measure_repair_burden: unknown option " + key)
				quit(2)
				return
	if city != "starter" and city != "bench":
		printerr("measure_repair_burden: --city must be starter|bench")
		quit(2)
		return
	_load_surfaces()
	print("repair burden · city=%s · %d game-days · seeds %s · strategies %s"
			% [city, days, str(seeds), str(strategies)])
	for strategy_id in strategies:
		for seed_value in seeds:
			_one(city, strategy_id, int(seed_value), days, absence, bucket)
	quit(0)


func _boot(city: String, seed_value: int) -> CitySim:
	if city == "starter":
		return CitySim.boot_from_files(seed_value)
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(BENCH_CITY),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	if not sim.boot_errors.is_empty():
		printerr("measure_repair_burden: %d boot error(s)" % sim.boot_errors.size())
		for message in sim.boot_errors:
			printerr("  " + String(message))
	return sim


func _load_surfaces() -> void:
	var notifications: Dictionary = StarterCityLoader.read_json("res://data/notifications.json")
	for entry in notifications.get("bindings", []):
		if entry is Dictionary and (entry as Dictionary).has("type"):
			_bindings.append(entry)
	var events: Dictionary = notifications.get("events", {})
	for notify_id in events:
		if events[notify_id] is Dictionary:
			_notify_classes[String(notify_id)] = String((events[notify_id] as Dictionary)
					.get("class", ""))
	var ui: Dictionary = StarterCityLoader.read_json("res://data/ui.json")
	for entry in (ui.get("event_log", {}) as Dictionary).get("events", []):
		if entry is Dictionary and (entry as Dictionary).has("type"):
			_log_rules.append(entry)


static func _matches(raw_match: Variant, event: Dictionary) -> bool:
	if not (raw_match is Dictionary):
		return true
	for key: String in (raw_match as Dictionary):
		if not event.has(key):
			return false
		var wanted: Variant = (raw_match as Dictionary)[key]
		var got: Variant = event[key]
		if wanted is bool or got is bool:
			if bool(wanted) != bool(got):
				return false
		elif wanted is float or wanted is int:
			if not is_equal_approx(float(wanted), float(got)):
				return false
		elif String(wanted) != String(got):
			return false
	return true


## The doc 08 class an event would be OFFERED to (before any budget), or "".
func _push_class(event: Dictionary) -> String:
	var type := String(event.get("type", ""))
	for entry in _bindings:
		var binding: Dictionary = entry
		if String(binding.get("type", "")) != type:
			continue
		if not _matches(binding.get("match", null), event):
			continue
		if binding.has("class"):
			return String(binding["class"])
		return String(_notify_classes.get(String(binding.get("notify_id", "")), ""))
	return ""


func _has_log_row(event: Dictionary) -> bool:
	var type := String(event.get("type", ""))
	for entry in _log_rules:
		var rule: Dictionary = entry
		if String(rule.get("type", "")) == type and _matches(rule.get("match", null), event):
			return true
	return false


## Is this archetype kept up by its OWNER (doc 02 §2.6a, Wave 17)? Asked of the
## catalog rather than of a `Building` field so this instrument runs unchanged on
## both sides of the ruling: a pre-Wave-17 tree has no `owner_maintained()`
## accessor, answers false for everything, and the affordance counter below
## therefore reports exactly the REPAIR rows that tree draws. The BEFORE and the
## AFTER in doc 92 §43.1 are taken with one binary and one script.
func _owner_kept(sim: CitySim, archetype: String) -> bool:
	if not sim.catalog.has_method("owner_maintained"):
		return false
	return bool(sim.catalog.call("owner_maintained", archetype))


func _class_of(sim: CitySim, sim_id: String) -> String:
	var b: Building = sim.buildings.get(sim_id)
	if b == null:
		return "?"
	var tax_class := sim.catalog.tax_class(String(b.archetype))
	return "private" if PRIVATE_CLASSES.has(tax_class) else "civic"


static func _band(condition: float) -> int:
	for i in BANDS.size():
		if condition >= float(BANDS[i]):
			return i
	return BANDS.size()


func _one(city: String, strategy_id: String, seed_value: int, days: int,
		absence: int, bucket: int) -> void:
	var sim := _boot(city, seed_value)
	var strategy := Playtest.Factory.make(strategy_id)
	if strategy == null:
		printerr("unknown strategy " + strategy_id)
		return
	var api := Playtest.Api.new(sim)
	sim.bus.drain()

	var band_of: Dictionary = {}
	for id in sim.buildings:
		band_of[String(id)] = _band((sim.buildings[id] as Building).condition)

	var rows: Array[Dictionary] = []
	var day := _fresh_row()
	var total_hours := days * HOURS_PER_DAY
	for h in total_hours:
		api.hour = h
		strategy.act(api, h)
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			_tally(sim, event, day)
		var settled: Dictionary = sim.last_settlement
		var expenses: Dictionary = settled.get("expenses", {})
		day["net"] += float(settled.get("net", 0.0))
		# `building_maint` is RETIRED since Wave 17 (doc 93 §Y1) and the snapshot
		# carries no such key, so this reads 0 on any build after the ruling. It
		# stays because the column is the BEFORE side of doc 92 §43.1's table and
		# an instrument that can no longer take the measurement it was built for
		# cannot re-check the claim it was built to prove.
		day["maint"] += float(expenses.get("building_maint", 0.0))
		day["roads"] += float(expenses.get("roads_repair", 0.0))
		if (h + 1) % HOURS_PER_DAY == 0:
			_close_day(sim, day, band_of)
			rows.append(day)
			day = _fresh_row()

	print("")
	print("== %s · seed %d · %s · %d game-days" % [strategy_id, seed_value, city, days])
	print("| days | net $/day | repair $ private | repair $ civic | trips priv/civ | "
			+ "upkeep $ (city pays, private stock) | roads accrual $ | repair share of net | "
			+ "dmg priv (decay/inc) | dmg civ | destroyed | ↓0.85 | ↓0.60 | ↓0.35 | "
			+ "push P1/P2/P3 | log rows | REPAIR shown priv/civ | worn<0.85 priv/civ |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	var total := _fresh_row()
	var first := 0
	while first < rows.size():
		var last := mini(rows.size(), first + bucket)
		var agg := _fresh_row()
		for i in range(first, last):
			_add_row(agg, rows[i])
			_add_row(total, rows[i])
		# End-of-window snapshot columns are the LAST day's, not a sum.
		for key in ["repair_shown_private", "repair_shown_civic", "worn_private",
				"worn_civic"]:
			agg[key] = rows[last - 1][key]
		var span := float(last - first)
		var repair_total := float(agg["repair_private"]) + float(agg["repair_civic"]) \
				+ float(agg["maint"])
		print("| %d–%d | %.0f | %.0f | %.0f | %d/%d | %.0f | %.0f | %.1f%% | %d/%d | %d | %d | %d | %d | %d | %d/%d/%d | %d | %d/%d | %d/%d |"
				% [first + 1, last, float(agg["net"]) / span,
				float(agg["repair_private"]), float(agg["repair_civic"]),
				int(agg["trips_private"]), int(agg["trips_civic"]),
				float(agg["maint"]), float(agg["roads"]),
				100.0 * repair_total / maxf(1.0, float(agg["net"])),
				int(agg["damaged_private_decay"]), int(agg["damaged_private_incident"]),
				int(agg["damaged_civic"]), int(agg["destroyed"]),
				int(agg["cross_085"]), int(agg["cross_060"]), int(agg["cross_035"]),
				int(agg["push_p1"]), int(agg["push_p2"]), int(agg["push_p3"]),
				int(agg["log_rows"]),
				int(agg["repair_shown_private"]), int(agg["repair_shown_civic"]),
				int(agg["worn_private"]), int(agg["worn_civic"])])
		first = last
	var repair_all := float(total["repair_private"]) + float(total["repair_civic"])
	print("TOTAL %d days: net $%.0f · building repairs $%.0f (private $%.0f = %.1f%%, civic $%.0f) · "
			% [rows.size(), float(total["net"]), repair_all, float(total["repair_private"]),
			100.0 * float(total["repair_private"]) / maxf(1.0, repair_all),
			float(total["repair_civic"])]
			+ "city upkeep on private stock $%.0f · roads accrual $%.0f · (repairs+upkeep)/net %.2f%% · repairs/net %.2f%%"
			% [float(total["maint"]), float(total["roads"]),
			100.0 * (repair_all + float(total["maint"])) / maxf(1.0, float(total["net"])),
			100.0 * repair_all / maxf(1.0, float(total["net"]))])
	print("      trips private %d · civic %d · damaged private %d (decay %d / incident %d) · damaged civic %d · destroyed %d · crossings 0.85/0.60/0.35 = %d/%d/%d"
			% [int(total["trips_private"]), int(total["trips_civic"]),
			int(total["damaged_private_decay"]) + int(total["damaged_private_incident"]),
			int(total["damaged_private_decay"]), int(total["damaged_private_incident"]),
			int(total["damaged_civic"]), int(total["destroyed"]),
			int(total["cross_085"]), int(total["cross_060"]), int(total["cross_035"])])
	print("      surfaces: push-class offers P1 %d / P2 %d / P3 %d · event-log rows %d · repair-family events reaching NO surface: %d"
			% [int(total["push_p1"]), int(total["push_p2"]), int(total["push_p3"]),
			int(total["log_rows"]), int(total["silent"])])
	print("      end state: min condition %.3f · REPAIR affordance shown on %d private / %d civic buildings · state_hash %s"
			% [api.min_condition(), int(rows[-1]["repair_shown_private"]),
			int(rows[-1]["repair_shown_civic"]), sim.state_hash()])

	if absence > 0:
		_absence(sim, absence)


func _fresh_row() -> Dictionary:
	return {"net": 0.0, "repair_private": 0.0, "repair_civic": 0.0,
			"trips_private": 0, "trips_civic": 0, "maint": 0.0, "roads": 0.0,
			"damaged_private_decay": 0, "damaged_private_incident": 0, "damaged_civic": 0,
			"destroyed": 0, "cross_085": 0, "cross_060": 0, "cross_035": 0,
			"push_p1": 0, "push_p2": 0, "push_p3": 0, "log_rows": 0, "silent": 0,
			"repair_shown_private": 0, "repair_shown_civic": 0,
			"worn_private": 0, "worn_civic": 0}


static func _add_row(into: Dictionary, row: Dictionary) -> void:
	for key in row:
		if row[key] is float:
			into[key] = float(into.get(key, 0.0)) + float(row[key])
		else:
			into[key] = int(into.get(key, 0)) + int(row[key])


## The repair family: the events a player would read as "something needs
## fixing", and what each one is offered to.
const REPAIR_FAMILY := ["building_damaged", "building_destroyed", "repair_started_sim",
		"building_repaired", "road_condition_critical", "road_collapsed",
		"water_main_break", "water_freeze_break", "water_node_failed", "water_pump_failed",
		"water_treatment_failed", "water_source_failed", "water_repair_completed",
		"PowerComponentFailed", "PowerComponentTripped"]


func _tally(sim: CitySim, event: Dictionary, day: Dictionary) -> void:
	var type := String(event.get("type", ""))
	match type:
		"repair_started_sim":
			var cls := _class_of(sim, String(event.get("sim_id", "")))
			if cls == "private":
				day["repair_private"] += float(event.get("cost", 0))
				day["trips_private"] += 1
			else:
				day["repair_civic"] += float(event.get("cost", 0))
				day["trips_civic"] += 1
		"building_damaged":
			var cls2 := _class_of(sim, String(event.get("sim_id", "")))
			var cause := String(event.get("cause", ""))
			if cls2 == "private":
				if cause == "decay":
					day["damaged_private_decay"] += 1
				else:
					day["damaged_private_incident"] += 1
			else:
				day["damaged_civic"] += 1
		"building_destroyed":
			day["destroyed"] += 1
	if not REPAIR_FAMILY.has(type):
		return
	var push := _push_class(event)
	var logged := _has_log_row(event)
	match push:
		"P1_critical": day["push_p1"] += 1
		"P2_important": day["push_p2"] += 1
		"P3_routine": day["push_p3"] += 1
	if logged:
		day["log_rows"] += 1
	if push == "" and not logged:
		day["silent"] += 1


func _close_day(sim: CitySim, day: Dictionary, band_of: Dictionary) -> void:
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		var key := String(id)
		if b.state == &"destroyed" or b.state == &"planned":
			band_of[key] = BANDS.size()
			continue
		var cls := _class_of(sim, key)
		var now := _band(b.condition)
		var was := int(band_of.get(key, 0))
		if now > was:
			if was < 1 and now >= 1:
				day["cross_085"] += 1
			if was < 2 and now >= 2:
				day["cross_060"] += 1
			if was < 3 and now >= 3:
				day["cross_035"] += 1
		band_of[key] = now
		# The building panel's own rule (`ui/build_controller.gd.repair_view`):
		# the REPAIR row is drawn unless the sim says there is nothing to buy —
		# `E_NOT_DAMAGED` at condition 1.00, and since Wave 17 `E_OWNER_MAINTAINED`
		# on private stock at ANY condition (doc 02 §2.6a).
		if (b.state == &"active" or b.state == &"damaged") \
				and b.condition < 1.0 and not _owner_kept(sim, String(b.archetype)):
			day["repair_shown_" + cls] += 1
		if b.condition < 0.85:
			day["worn_" + cls] += 1


## One night away: doc 01's capped catch-up, on the coarse path, with
## `is_catchup` true so the structural-failure roll is held exactly as it is
## for a real absence (doc 08 C-47).
func _absence(sim: CitySim, hours: int) -> void:
	var before_balance := sim.treasury.balance
	sim.bus.drain()
	sim.advance_coarse_hours(hours, true)
	var damaged := {"private": 0, "civic": 0}
	var destroyed := {"private": 0, "civic": 0}
	var bands := {"private": [0, 0, 0, 0], "civic": [0, 0, 0, 0]}
	var bill := {"private": 0, "civic": 0}
	var bill_count := {"private": 0, "civic": 0}
	var events_damaged := 0
	for event in sim.bus.drain():
		if String(event.get("type", "")) == "building_damaged":
			events_damaged += 1
	# The state census of everything below the auto-damage line. Doc 93 §Y1a
	# claims a private building can only get there by being left DARK, and the
	# claim is only checkable if the states are printed beside the bands: a
	# building under 0.35 that is not `damaged` is a building some other doc's
	# state machine is holding, and this line is what says which.
	var low_states: Dictionary = {}
	var m_repair := float(sim.treasury.difficulty().get("M_repair", 1.0))
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		var cls := _class_of(sim, String(id))
		if b.state == &"destroyed":
			destroyed[cls] += 1
			continue
		if b.state == &"planned" or b.state == &"under_construction":
			continue
		if b.state == &"damaged":
			damaged[cls] += 1
		(bands[cls] as Array)[_band(b.condition)] += 1
		if b.condition < 0.35:
			var key := "%s/%s" % [cls, String(b.state)]
			low_states[key] = int(low_states.get(key, 0)) + 1
		# **The morning bill is what the CITY CAN BUY**, which since Wave 17 is the
		# city's own assets only (doc 02 §2.6a): a private building under the
		# threshold has no purchasable repair at any price, so quoting one would
		# print a number the player can never be charged and can never pay. On a
		# pre-Wave-17 tree `_owner_kept` answers false for everything and this
		# reads exactly as it did — which is how the BEFORE side of doc 92 §43.1
		# was taken.
		if b.condition < MAINTAINER_THRESHOLD \
				and not _owner_kept(sim, String(b.archetype)):
			# `CostCurves.resolve_type` maps doc 02's archetype id onto its doc 03
			# money row (`water_facility` → `water_plant`), so the quote is C-16's.
			bill[cls] += sim.econ_curves.repair_cost_building(String(b.archetype),
					maxi(b.level, 1), b.damage_fraction(), m_repair)
			bill_count[cls] += 1
	print("   AFTER %d game-hours away (%.0f game-days, capped catch-up): treasury %d → %d"
			% [hours, float(hours) / float(HOURS_PER_DAY), before_balance, sim.treasury.balance])
	for cls in ["private", "civic"]:
		var row: Array = bands[cls]
		print("      %-7s bands Good/Worn/Poor/Failing = %d/%d/%d/%d · damaged %d · destroyed %d · morning bill (under %.2f): %d buildings, $%d"
				% [cls, int(row[0]), int(row[1]), int(row[2]), int(row[3]),
				int(damaged[cls]), int(destroyed[cls]), MAINTAINER_THRESHOLD,
				int(bill_count[cls]), int(bill[cls])])
	print("      building_damaged events during the absence: %d · min condition %.3f"
			% [events_damaged, Playtest.Api.new(sim).min_condition()])
	if not low_states.is_empty():
		var census: Array[String] = []
		for key in low_states:
			census.append("%s x%d" % [String(key), int(low_states[key])])
		census.sort()
		print("      below the auto-damage line, by state: " + ", ".join(census))
