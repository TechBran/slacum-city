extends SceneTree
## Wave-20 Lane-1 instrument (doc 92 §58). **THE ACCEPTANCE TEST IS A REAL
## PLAYER'S REAL CITY, AND IT IS ON DISK.**
##
## Every previous catastrophe measurement in this project — `probe_neglect.gd`,
## `measure_catastrophe.gd`, the whole doc 92 §56 pass — was taken on a city
## this repository generated. That is why Wave 19 could publish an $83,398
## relief grant for a 251-ruin *standard* city and still ship a build in which
## the player's own 41-population save collects **$0** of relief in fourteen
## game-days. A generated city is a model of the player's city; a save file is
## the player's city.
##
## So this tool loads a real slot through the real `SaveService` — the same
## ladder, the same seven-check gate, the same `restore_state` — advances it on
## the real coarse path, and prints the census in the shape the report asks for:
## ALIVE and DESTROYED, grouped by `private` / `CIVIC` (doc 02 §2.6a's
## `owner_maintained`) and by archetype, plus the trajectory that says whether
## the city is falling or climbing.
##
##   ~/.local/bin/godot --headless --path <repo> \
##       -s res://tools/measure_player_city.gd -- --saves=<dir> [opts]
##
##   --saves=DIR    directory holding `slot_N/` and/or `slot_N.json`; copied
##                  into this run's PRIVATE `user://saves` (see below).
##                  Required — there is no default, because a default would be
##                  another agent's save directory.
##   --slot=N       slot to load (default 0)
##   --days=N       game-days to advance after the load (default 14)
##   --marks=a,b    ALSO print the full census at these game-day marks
##                  (default `14,45`) — one run, two published censuses.
##   --rows         per-game-day trajectory table
##   --stride=N     print every Nth day row (default 1)
##   --catchup      advance as an ABSENCE (doc 08 C-47 suppression) instead of
##                  an online fast-forward. Default is online, which is the arm
##                  the player's report describes and the arm gate 29 uses.
##   --json=FILE    also write the censuses as JSON, for a diff between builds
##   --restore[=N]  ALSO play the one verb a fallen city has: once a game-day,
##                  restore every ruin the treasury can pay for above the
##                  reserve N, cheapest first
##   --spine-first  as --restore, but buy doc 93 §AR1's utility spine first
##   --fire-dept=A  **DOC 93 §AV4's INCENTIVE SWEEP.** Three arms that differ in
##                  the fire department and in NOTHING else:
##                    keep — reinstate every `fire_station` at condition 1.0 and
##                           PIN it there, so it can never wear out
##                    burn — reinstate it once and then leave it alone
##                    none — the city owns no fire department at all: the shells
##                           stay rubble AND `FleetSystem.remove_station` retires
##                           their engines, which is the player's own bulldoze
##                           and the one door that ends a service (§AV1)
##                  The reinstatement is FREE in every arm on purpose: charging
##                  it would make the arms differ by a restore bill as well as by
##                  a department, and then no delta could be attributed.
##   --service-audit  print the fleet-and-capability reading the §AV1 predicate
##                  actually sees, at load and at every mark
##
## **`user://` IS SHARED AND THIS TOOL WRITES INTO IT.** Every worktree of this
## project resolves `user://` to the same
## `~/.local/share/godot/app_userdata/Slacum City`, and the save the acceptance
## test needs has to be *in* `user://saves` for `SaveService` to find it. Copying
## it there for real would clobber whatever another agent is holding. So this
## tool takes a private `user://` for the process — the same two ProjectSettings
## switches plus `XDG_DATA_HOME` that `tests/user_dir_isolation.gd` uses, and for
## its reasons — copies the slot in there, and sweeps it at exit. Nothing outside
## the private directory is read, written or removed.
##
## It is a MEASURING instrument (constitution §3): it boots the real `CitySim`,
## owns no constant, and is never imported by `sim/`.

const HOURS_PER_DAY := 24
## Every terminal cause `Building._destroy` can be handed, in print order.
const DESTROY_CAUSES := ["damage", "fire", "structural_failure", "demolish"]
## Marks the private `user://` this tool creates, and the ONLY path its sweep
## will touch — `tests/user_dir_isolation.gd`'s guard, restated because a tool
## in `tools/` may not import a class out of `tests/`.
const DIR_MARK := "slacum-playercity-"
## Doc 93 §AR1's utility spine, restated for the `--spine-first` arm only. It is
## a MEASUREMENT ordering and owns no rule — `data/building_rules.json` is the
## authority — and nothing outside that arm reads it.
const SPINE_ARCHETYPES := ["power_facility", "substation", "water_facility"]

var _user_dir := ""
var _pending_incidents := 0


func _initialize() -> void:
	var saves := ""
	var slot := 0
	var days := 14
	var marks: Array[int] = [14, 45]
	var rows := false
	var stride := 1
	var catchup := false
	var json_path := ""
	## Doc 92 §58.6's arm: does the city the rulings SAVE have anything to spend?
	var restoring := false
	var restore_reserve := 20000
	## Doc 92 §60.8's second agent. The cheapest-first arm is deliberately the
	## dumbest possible player, and on a city whose generation is a ruin the
	## cheapest ruins are never the ones that matter. This arm changes exactly one
	## thing — it buys doc 93 §AR1's utility spine before anything else — so the
	## difference between the two runs is attributable to that single decision.
	var spine_first := false
	## Doc 93 §AV4's arm selector — "", "keep", "burn" or "none".
	var fire_dept := ""
	var service_audit := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--saves="):
			saves = arg.substr(8)
		elif arg.begins_with("--slot="):
			slot = int(arg.substr(7))
		elif arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--marks="):
			marks = []
			for piece in arg.substr(8).split(",", false):
				marks.append(int(piece))
		elif arg == "--rows":
			rows = true
		elif arg.begins_with("--stride="):
			stride = maxi(1, int(arg.substr(9)))
		elif arg == "--catchup":
			catchup = true
		elif arg.begins_with("--json="):
			json_path = arg.substr(7)
		elif arg.begins_with("--restore="):
			restore_reserve = int(arg.substr(10))
			restoring = true
		elif arg == "--restore":
			restoring = true
		elif arg == "--spine-first":
			restoring = true
			spine_first = true
		elif arg.begins_with("--fire-dept="):
			fire_dept = arg.substr(12)
		elif arg == "--service-audit":
			service_audit = true
	if saves == "":
		printerr("measure_player_city: --saves=DIR is required")
		quit(2)
		return
	for mark in marks:
		days = maxi(days, mark)

	_isolate_user_dir()
	var copied := _copy_saves(saves)
	if copied == 0:
		printerr("measure_player_city: nothing copied out of " + saves)
		_sweep()
		quit(2)
		return
	print("measure_player_city: %d save entries -> %s" % [copied, _user_dir])

	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	root.add_child(service)
	if not service.load_slot(sim, slot):
		printerr("measure_player_city: slot %d did not load" % slot)
		root.remove_child(service)
		service.free()
		sim.dispose()
		_sweep()
		quit(2)
		return
	# **The head-align, and it is not a detail.** A save is written when the
	# player pauses, so its `sim_time_minutes` is almost never on an hour
	# boundary — this slot's is 239,884, i.e. 4.4 minutes past game-hour 3,998 —
	# and `TickScheduler.advance_coarse_n` asserts hour alignment. This is
	# `CatchUpPlanner.plan()`'s own first segment, restated: fine-tick up to the
	# next hour, then advance coarse. Without it the assert fires 336 times and
	# the city does not move at all, which reads exactly like a city that has
	# stopped falling.
	var misalign := sim.clock.tick_index % GameClock.TICKS_PER_HOUR
	if misalign != 0:
		sim.scheduler.advance_fine_n(GameClock.TICKS_PER_HOUR - misalign)
	sim.bus.drain()

	if fire_dept != "":
		print("measure_player_city: fire-dept arm '%s' -> %s"
				% [fire_dept, _apply_fire_dept_arm(sim, fire_dept)])

	var report := {"marks": [] as Array}
	print("")
	print("=== AT LOAD (game-day %d, treasury $%d, population %d, preset %s) ==="
			% [_game_day(sim), int(sim.treasury.balance),
			int(sim.population.city_population), sim.difficulty_preset()])
	var at_load := _census(sim)
	_print_census(at_load)
	_print_ladder(sim)
	print("  " + _ruin_bill_line(sim))
	if service_audit:
		print("  " + _service_line(sim))
	report["at_load"] = at_load

	if catchup and sim.director != null:
		sim.director.catchup_begin()
	var destroyed_by_cause := {}
	var damaged_by_cause := {}
	# **Attribution by DIFF, not by event, and that is a finding not a style**
	# (doc 91 A91-D-110). `CityIncidentWorld.destroy_building` calls
	# `Building.burn_down` / `Building.demolish` and DROPS the event array both
	# of them return, so doc 06's cascade ops take buildings down without ever
	# announcing it on the bus. A tool that trusted the bus would report 1
	# destruction where the census shows 12. So the roster's states are snapshot
	# every game-hour and diffed; an event that names the same building in the
	# same hour supplies the cause, and a destruction with no event is counted
	# as `SILENT` — which is exactly the number that measures the defect.
	var was_state := {}
	for id in sim.roster_ids():
		was_state[id] = (sim.buildings[id] as Building).state
	var relief_paid := 0
	var relief_grants := 0
	var day_rows: Array[Dictionary] = []
	var total := days * HOURS_PER_DAY
	var restored := 0
	var repaired := 0
	for h in total:
		if fire_dept == "keep":
			_pin_fire_departments(sim)
		if restoring and h % HOURS_PER_DAY == 0:
			restored += _restore_what_it_can_afford(sim, restore_reserve,
					spine_first, fire_dept == "none")
			repaired += _repair_what_it_can_afford(sim, restore_reserve)
		sim.scheduler.advance_coarse_n(1, catchup, h, total)
		_tally(sim, destroyed_by_cause, damaged_by_cause)
		_attribute(sim, was_state, destroyed_by_cause)
		relief_paid += _relief_this_hour
		relief_grants += _relief_grants_this_hour
		if (h + 1) % HOURS_PER_DAY != 0:
			continue
		var day: int = (h + 1) / HOURS_PER_DAY
		day_rows.append(_day_row(sim, day, destroyed_by_cause, relief_paid))
		if marks.has(day):
			print("")
			print("=== AFTER %d GAME-DAYS (treasury $%d, population %d) ==="
					% [day, int(sim.treasury.balance),
					int(sim.population.city_population)])
			var mark_census := _census(sim)
			_print_census(mark_census)
			_print_ladder(sim)
			print("  destroyed this run, by cause: " + _causes(destroyed_by_cause))
			print("  last settled hour: " + _settlement_line(sim))
			print("  " + _ruin_bill_line(sim))
			print("  relief paid this run: $%d in %d grant(s)" % [relief_paid, relief_grants])
			print("  unanswered: " + str(_unanswered))
			if service_audit:
				print("  " + _service_line(sim))
			print("  bus, top event types: " + _top_events(12))
			if restoring:
				print("  restored this run: %d ruins, repaired %d shells"
						% [restored, repaired] + " (reserve $%d)" % restore_reserve)
			mark_census["day"] = day
			mark_census["destroyed_by_cause"] = destroyed_by_cause.duplicate()
			mark_census["relief_paid"] = relief_paid
			(report["marks"] as Array).append(mark_census)

	if rows:
		print("")
		print("  day | standing ruins damaged condemned | dark | treasury deferred"
				+ " credit | relief$ | pop | meanC")
		for row in day_rows:
			if int(row["day"]) % stride != 0 and int(row["day"]) != days:
				continue
			print("  %3d | %8d %5d %7d %9d | %4d | %8d %8d %6d | %7d | %4d | %.3f" % [
				int(row["day"]), int(row["standing"]), int(row["ruins"]),
				int(row["damaged"]), int(row["condemned"]), int(row["dark"]),
				int(row["treasury"]), int(row["deferred"]), int(row["credit_limit"]),
				int(row["relief_paid"]), int(row["population"]),
				float(row["mean_condition"])])

	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(report, "  "))
			f.close()
			print("\n  json -> " + json_path)

	# Out of the tree and freed BEFORE the sweep: `SaveService._ready` recreates
	# `user://saves`, so a node still alive when the private directory goes would
	# print an error about a path this tool had just removed.
	root.remove_child(service)
	service.free()
	sim.dispose()
	_sweep()
	quit(0)


# ------------------------------------------------------------------ the census

## The report's own shape: ALIVE and DESTROYED, keyed `private/<archetype>` and
## `CIVIC/<archetype>`, because doc 02 §2.6a's ownership split is the axis every
## Wave-19 and Wave-20 ruling turns on and a census that hid it would not be able
## to say whether the utility spine survived.
##
## `condemned` is counted separately from `damaged` even though it IS a
## `damaged` building: doc 93 §AP1's condemn-instead-of-destroy rule is only
## visible as a number if the buildings resting at the structural-failure line
## are counted, and "damaged" alone cannot tell a building an incident hurt
## yesterday from one that has stopped falling for good.
func _census(sim: CitySim) -> Dictionary:
	var alive := {}
	var destroyed := {}
	var condemned := 0
	var damaged := 0
	var dark := 0
	var threshold := 0.0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		var key := "%s/%s" % ["private" if b.owner_maintained else "CIVIC", b.archetype]
		if b.state == &"destroyed":
			destroyed[key] = int(destroyed.get(key, 0)) + 1
			continue
		alive[key] = int(alive.get(key, 0)) + 1
		if b.state == &"damaged":
			damaged += 1
			threshold = b.rule("structural_failure_threshold")
			if b.condition <= threshold + 0.0001:
				condemned += 1
		if b.archetype != &"substation" \
				and sim.grid.power_availability_hour(String(id)) <= 0.0:
			dark += 1
	return {
		"alive": alive, "destroyed": destroyed,
		"alive_total": _sum(alive), "destroyed_total": _sum(destroyed),
		"damaged": damaged, "condemned": condemned, "dark": dark,
		"treasury": int(sim.treasury.balance),
		"deferred": int(sim.treasury.deferred_liability),
		"credit_limit": int(sim.treasury.credit_limit),
		"population": int(sim.population.city_population),
		"city_level": int(sim.progression.city_level),
		"game_day": _game_day(sim),
	}


func _print_census(census: Dictionary) -> void:
	print("  ALIVE      (%d): %s" % [int(census["alive_total"]),
			_tally_line(census["alive"])])
	print("  DESTROYED  (%d): %s" % [int(census["destroyed_total"]),
			_tally_line(census["destroyed"])])
	print("  of the living: %d damaged, of which %d condemned (resting at the"
			% [int(census["damaged"]), int(census["condemned"])]
			+ " structural-failure line); %d dark" % int(census["dark"]))


func _print_ladder(sim: CitySim) -> void:
	var t := sim.treasury
	print("  ladder: treasury $%d | deferred $%d | credit limit $%d"
			% [int(t.balance), int(t.deferred_liability), int(t.credit_limit)]
			+ " | relief used %d/%d in era (level %d) | austerity %s"
			% [t.relief_grants_used,
			int(t.difficulty().get("relief_grants_per_era", 0)),
			t.relief_era_level, str(t.austerity_active)]
			+ " | outstanding restore bill $%d" % int(sim.outstanding_restore_cost()))


## Doc 03 §2.4's expense lines for the LAST settled game-hour, which is the only
## honest answer to "where is the relief going?". A city with no revenue and no
## buildings is still being billed something, and the line that is doing it has
## to be named rather than guessed at.
func _settlement_line(sim: CitySim) -> String:
	var settled := sim.last_settlement
	if settled.is_empty():
		return "(none)"
	var revenue: Dictionary = settled.get("revenue", {})
	var expenses: Dictionary = settled.get("expenses", {})
	var parts: Array[String] = []
	var keys := expenses.keys()
	keys.sort()
	for key in keys:
		if String(key) == "total":
			continue
		var value := float(expenses[key])
		if absf(value) >= 0.005:
			parts.append("%s $%.2f" % [key, value])
	return "gross $%.2f/gh, expense $%.2f/gh (%s)" % [
			float(revenue.get("gross", 0.0)), float(expenses.get("total", 0.0)),
			", ".join(parts) if not parts.is_empty() else "nothing"]


## **WHO IS BEING BILLED?** Doc 03 §2.4's `E_building_maint` and `E_departments`
## are both computed from `CitySim.build_settlement_inputs`, which walks
## `roster_ids()` — and `roster_ids()` includes RUINS. So this splits both lines
## the way the settlement never does: what the city pays for buildings that are
## still standing, and what it pays for buildings that are rubble.
##
## The arithmetic is doc 03's own, restated here for measurement only and read
## out of `data/economy.json` rather than retyped (C-07): a ruin has
## `condition == 0`, so `E_building_maint`'s
## `(1 + MAINT_CONDITION_PENALTY x (1 - condition))` is at its MAXIMUM 2.5 and
## `E_departments`' `(1 + ASSET_CONDITION_PENALTY_COEFF x (1 - condition))` is at
## its maximum 3.0. A destroyed building is billed more than a perfect one.
func _ruin_bill_line(sim: CitySim) -> String:
	var expenses: Dictionary = sim.econ_curves.economy_data().get("expenses", {})
	var maint_rate := float(expenses.get("BUILDING_MAINT_RATE", 0.0))
	var maint_penalty := float(expenses.get("MAINT_CONDITION_PENALTY", 0.0))
	var asset_penalty := float(expenses.get("ASSET_CONDITION_PENALTY_COEFF", 0.0))
	var standing_maint := 0.0
	var ruin_maint := 0.0
	var standing_dept := 0.0
	var ruin_dept := 0.0
	var ruin_stations := 0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		var type := String(b.archetype)
		var ruin := b.state == &"destroyed"
		if sim.econ_curves.is_revenue_producing(type):
			var capital := float(sim.econ_curves.capital_value(type, maxi(b.level, 1)))
			var bill := capital * maint_rate * (1.0 + maint_penalty * (1.0 - b.condition))
			if ruin:
				ruin_maint += bill
			else:
				standing_maint += bill
			continue
		if not [&"police_station", &"fire_station", &"construction_yard"].has(b.archetype):
			continue
		var upkeep := sim.economy.station_upkeep(type, maxi(b.level, 1), false) \
				* (1.0 + asset_penalty * (1.0 - clampf(b.condition, 0.0, 1.0)))
		if ruin:
			ruin_dept += upkeep
			ruin_stations += 1
		else:
			standing_dept += upkeep
	# A CATALOGUE COUNTERFACTUAL — what the pre-Wave-23 rules would bill for
	# rubble — printed beside the settled ledger so the two can be compared. The
	# settled `E_departments` line above is the authority (doc 93 §AV3 settles
	# it at $0.00 for rubble); this line is deliberately NOT changed by §AV3.
	return ("ruin bill IF RUBBLE WERE STILL STAFFED (catalogue counterfactual, not the"
			+ " settled ledger): building_maint $%.2f/gh of $%.2f, departments"
			+ " $%.2f/gh of $%.2f (%d ruined stations still staffed)"
			+ " -> $%.2f/gh, $%d/game-day") % [
			ruin_maint, ruin_maint + standing_maint,
			ruin_dept, ruin_dept + standing_dept, ruin_stations,
			ruin_maint + ruin_dept, int((ruin_maint + ruin_dept) * 24.0)]


## The loudest lines on the bus, descending. Doc 93 §AS3's number.
func _top_events(limit: int) -> String:
	var keys := _types_total.keys()
	keys.sort_custom(func(x: Variant, y: Variant) -> bool:
		if int(_types_total[x]) != int(_types_total[y]):
			return int(_types_total[x]) > int(_types_total[y])
		return String(x) < String(y))
	var parts: Array[String] = []
	var shown := 0
	for key in keys:
		if shown >= limit:
			break
		parts.append("%s=%d" % [String(key), int(_types_total[key])])
		shown += 1
	return ", ".join(parts)


func _tally_line(counts: Dictionary) -> String:
	if counts.is_empty():
		return "(none)"
	var keys := counts.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s x%d" % [key, int(counts[key])])
	return ", ".join(parts)


func _causes(by_cause: Dictionary) -> String:
	var parts: Array[String] = []
	for cause in DESTROY_CAUSES:
		parts.append("%s=%d" % [cause, int(by_cause.get(cause, 0))])
	for cause in by_cause:
		if not DESTROY_CAUSES.has(String(cause)):
			parts.append("%s=%d" % [cause, int(by_cause[cause])])
	return " ".join(parts)


func _sum(counts: Dictionary) -> int:
	var total := 0
	for key in counts:
		total += int(counts[key])
	return total


func _game_day(sim: CitySim) -> int:
	return int(sim.clock.sim_time_minutes() / (60 * HOURS_PER_DAY))


# ----------------------------------------------------------------- the advance

var _relief_this_hour := 0
var _relief_grants_this_hour := 0

## Per-building destruction causes the bus DID announce this hour, cleared and
## refilled by [_tally] so [_attribute] can join them to the roster diff.
var _destroyed_ids_this_hour := {}
var _types_this_hour := {}
## Every event type this run has seen, and how many times. **An event storm is
## its own defect** (doc 93 §AS3): a bus line that fires six figures of times in
## ninety game-days is not telling the player anything, it is drowning every
## other line, and no census can say so unless something counts.
var _types_total := {}
## Doc 93 §AR2's counters: incidents nobody could answer, and what they cost.
var _unanswered := {}

## Drains the bus once — it may only be drained once per game-hour — folding the
## destruction causes and the relief grants out of the same pass.
func _tally(sim: CitySim, destroyed: Dictionary, damaged: Dictionary) -> void:
	_pending_incidents = 0
	_relief_this_hour = 0
	_relief_grants_this_hour = 0
	_destroyed_ids_this_hour = {}
	_types_this_hour = {}
	for event in sim.bus.drain():
		var type := String(event["type"])
		_types_this_hour[type] = int(_types_this_hour.get(type, 0)) + 1
		_types_total[type] = int(_types_total.get(type, 0)) + 1
		if type == "incident_abandoned" or type == "incident_failed":
			_unanswered[type] = int(_unanswered.get(type, 0)) + 1
		elif type == "building_destroyed_by_fire":
			_unanswered["burned"] = int(_unanswered.get("burned", 0)) + 1
		elif type == "dispatch_blocked_unreachable":
			_unanswered["unreachable"] = int(_unanswered.get("unreachable", 0)) + 1
		if type == "building_destroyed":
			# Join on `sim_id`, not on `building`. `Building._destroy` stamps
			# `building` with the INT `Building.id`, while every roster key in
			# `CitySim.buildings` is the authored STRING sim_id ("P-077",
			# "H-001"); the two are different namespaces and joining on the wrong
			# one silently reports every destruction as unattributed. Both
			# publishers — `CitySim.apply_hourly_decay` and
			# `CityIncidentWorld._publish` — stamp `sim_id` for exactly this
			# reason.
			_destroyed_ids_this_hour[String(event.get("sim_id",
					str(event.get("building", ""))))] = \
					String(event.get("cause", "?"))
		elif type == "building_damaged":
			var dcause := String(event.get("cause", "?"))
			damaged[dcause] = int(damaged.get(dcause, 0)) + 1
		elif type == "incident_created":
			_pending_incidents += 1
		elif type == "relief_grant_awarded":
			_relief_this_hour += int(event.get("amount", 0))
			_relief_grants_this_hour += 1


## The roster diff. Every building that became a ruin this hour is counted once,
## under the cause the bus named for it or under `SILENT` when the bus named
## nothing — see the comment at the call site for why the second bucket exists.
func _attribute(sim: CitySim, was_state: Dictionary, destroyed: Dictionary) -> void:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		var before := StringName(was_state.get(id, b.state))
		was_state[id] = b.state
		if b.state != &"destroyed" or before == &"destroyed":
			continue
		var cause: String = _destroyed_ids_this_hour.get(String(id), "SILENT")
		destroyed[cause] = int(destroyed.get(cause, 0)) + 1
		var key := "%s:%s" % [cause, b.archetype]
		destroyed[key] = int(destroyed.get(key, 0)) + 1


func _day_row(sim: CitySim, day: int, destroyed_by_cause: Dictionary,
		relief_paid: int) -> Dictionary:
	var census := _census(sim)
	return {
		"day": day,
		"standing": int(census["alive_total"]),
		"ruins": int(census["destroyed_total"]),
		"damaged": int(census["damaged"]),
		"condemned": int(census["condemned"]),
		"dark": int(census["dark"]),
		"treasury": int(census["treasury"]),
		"deferred": int(census["deferred"]),
		"credit_limit": int(census["credit_limit"]),
		"relief_paid": relief_paid,
		"population": int(census["population"]),
		"mean_condition": _mean_condition(sim),
		"by_cause": destroyed_by_cause.duplicate(),
	}


func _mean_condition(sim: CitySim) -> float:
	var total := 0.0
	var counted := 0
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state == &"destroyed":
			continue
		total += b.condition
		counted += 1
	return total / maxf(1.0, float(counted))


## **DOC 93 §AV4's THREE ARMS.** The city on disk owns a fire station that is
## already rubble and a fire engine that outlived it, so every arm has to be
## CONSTRUCTED from that one save — and the only honest way to do that is to make
## the reinstatement free in all three, so the arms differ by the department and
## not by a restore bill. Returns a one-line description of what it did.
##
## `keep` and `burn` put the shell back at condition 1.0 and re-house its engines
## through the real `FleetSystem.sync_station`. `none` is the player's own
## bulldoze: the shell stays rubble and `remove_station` retires the engines,
## which under §AV1 is the one door in the game that ends a service.
func _apply_fire_dept_arm(sim: CitySim, arm: String) -> String:
	var touched := 0
	var units_before: int = sim.incidents.fleet.size()
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station":
			continue
		touched += 1
		if arm == "none":
			b.state = &"destroyed"
			b.condition = 0.0
			sim.incidents.fleet.remove_station(String(id))
			continue
		b.state = &"active"
		b.condition = 1.0
		b.level = maxi(b.level, 1)
		sim.incidents.fleet.sync_station(String(id), String(b.archetype),
				b.level, b.origin)
	return "%d station(s), fleet %d -> %d units, fire capability %s" % [
			touched, units_before, sim.incidents.fleet.size(),
			str(sim.incident_world.has_fire_capability())]


## The `keep` arm's pin, applied every game-hour: the department may not wear
## out, so any delta between `keep` and `burn` is maintenance and nothing else.
func _pin_fire_departments(sim: CitySim) -> void:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station":
			continue
		if b.state == &"damaged" or b.state == &"repairing":
			b.state = &"active"
		b.condition = 1.0


## What doc 93 §AV1's predicate actually sees, printed rather than inferred: the
## fleet by role, the two capability readings, and the answered/blocked split
## that says whether owning the service bought anything.
func _service_line(sim: CitySim) -> String:
	var fleet: FleetSystem = sim.incidents.fleet
	var by_role := {}
	for role in ["fire", "police", "utility", "water", "construction"]:
		var count := 0
		for unit_id in fleet.unit_ids_ref():
			var u: Vehicle = fleet.unit(int(unit_id))
			if u != null and u.has_capability_for(String(role)):
				count += 1
		by_role[role] = count
	# Doc 93 §AS1's SHELL half, restated here for one purpose: so the two
	# readings can be printed side by side on the same city at the same instant,
	# and §AV1's correction is a measurement rather than a derivation from the
	# diff. It owns no rule — `CityIncidentWorld` is the authority — and nothing
	# outside this line reads it.
	var standing := 0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station":
			continue
		if b.state == &"active" or b.state == &"damaged" or b.state == &"repairing":
			standing += 1
	var as1_reading := standing > 0 and int(by_role["fire"]) > 0
	return ("service: fire_station shells standing %d | fleet %d units"
			+ " (fire %d, police %d, utility %d, water %d, construction %d)"
			+ " | §AS1 shell reading %s -> §AV1 service reading %s"
			+ " | assigned %d, blocked_no_units %d, blocked_unreachable %d") % [
			standing, fleet.size(), int(by_role["fire"]), int(by_role["police"]),
			int(by_role["utility"]), int(by_role["water"]),
			int(by_role["construction"]), str(as1_reading),
			str(sim.incident_world.has_fire_capability()),
			int(_types_total.get("incident_assigned", 0)),
			int(_types_total.get("dispatch_blocked_no_units", 0)),
			int(_types_total.get("dispatch_blocked_unreachable", 0))]


## **DOES THE SAVED CITY HAVE ANYTHING TO SPEND?** (doc 92 §58.6.)
##
## The acceptance test is not "fewer ruins" — it is a city that **stops falling
## and starts climbing** — and a floor alone only proves the first half. So this
## arm plays the one verb a fallen city actually has: once a game-day, restore
## every ruin the treasury can pay for above `reserve`, cheapest first.
##
## It is deliberately the DUMBEST possible agent. It reads no coverage map, it
## does not prioritise the fire station, it does not tax and it does not build.
## If a city climbs under this agent it climbs under any player, and the climb is
## attributable to the rulings rather than to a strategy.
##
## `cmd_restore_building` is the real command with the real price
## (`CostCurves.restore_cost_building` at the city's own `M_repair`) charged
## through the real treasury, so nothing here is free.
func _restore_what_it_can_afford(sim: CitySim, reserve: int,
		spine_first: bool = false, skip_fire_stations: bool = false) -> int:
	var quotes: Array = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state != &"destroyed":
			continue
		# The `none` arm owns no fire department and does not buy one back; the
		# agent is otherwise identical, which is what makes the arms comparable.
		if skip_fire_stations and b.archetype == &"fire_station":
			continue
		var quote := sim.cmd_restore_building(id, true)
		var payload: Dictionary = quote.get("payload", {})
		if not (payload.get("blockers", [&"E"]) as Array).is_empty():
			continue
		var rank := 0
		if spine_first and SPINE_ARCHETYPES.has(String(b.archetype)):
			rank = -1
		quotes.append({"id": id, "cost": int(payload.get("cost", 0)), "rank": rank})
	# Cheapest first, ties broken by roster order, which is a total order — so
	# the arm is deterministic and re-runnable. `rank` is the ONLY thing the
	# spine-first arm changes, and it is 0 for every row in the default arm.
	quotes.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if int(x["rank"]) != int(y["rank"]):
			return int(x["rank"]) < int(y["rank"])
		if int(x["cost"]) != int(y["cost"]):
			return int(x["cost"]) < int(y["cost"])
		return String(x["id"]) < String(y["id"]))
	var done := 0
	for quote in quotes:
		var cost := int((quote as Dictionary)["cost"])
		if sim.treasury.balance - cost < reserve:
			# The spine-first arm does not STOP at the first thing it cannot
			# afford: a plant it is saving up for must not block the houses it
			# can buy today, or "spine first" would mean "spine only".
			if spine_first:
				continue
			break
		if bool(sim.cmd_restore_building(String((quote as Dictionary)["id"]),
				false).get("ok", false)):
			done += 1
	return done


## **AND THE OTHER VERB THE GAME OFFERS A FALLEN CITY** (doc 92 §60.7). Doc 93
## §AS1 condemns rather than destroys, so a city that has been through fires it
## could not answer is a city of SHELLS, not of ruins — and `cmd_restore_building`
## cannot see a shell, because a shell is not `destroyed`. An agent that only
## restored would therefore measure the ruling's floor and never its exit.
##
## Same shape as the restore arm and the same deliberate dumbness: once a
## game-day, every repair the treasury can pay for above `reserve`, cheapest
## first, through the real `cmd_repair_building` at doc 03's own price. It reads
## no coverage map and has no strategy.
func _repair_what_it_can_afford(sim: CitySim, reserve: int) -> int:
	var quotes: Array = []
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state != &"damaged" and b.state != &"active":
			continue
		var quote := sim.cmd_repair_building(String(id), true)
		var payload: Dictionary = quote.get("payload", {})
		if not (payload.get("blockers", [&"E"]) as Array).is_empty():
			continue
		quotes.append({"id": String(id), "cost": int(payload.get("cost", 0))})
	quotes.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if int(x["cost"]) != int(y["cost"]):
			return int(x["cost"]) < int(y["cost"])
		return String(x["id"]) < String(y["id"]))
	var done := 0
	for quote in quotes:
		var cost := int((quote as Dictionary)["cost"])
		if sim.treasury.balance - cost < reserve:
			break
		if bool(sim.cmd_repair_building(String((quote as Dictionary)["id"]),
				false).get("ok", false)):
			done += 1
	return done


# ------------------------------------------------------------ private user://

## The three switches `tests/user_dir_isolation.gd` documents, applied for its
## reasons: `user://` is keyed on `application/config/name`, which every
## worktree shares, and this tool has to write a save INTO it.
func _isolate_user_dir() -> void:
	var root_dir := OS.get_temp_dir().path_join("slacum-playercity")
	DirAccess.make_dir_recursive_absolute(root_dir)
	OS.set_environment("XDG_DATA_HOME", root_dir)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
			DIR_MARK + str(OS.get_process_id()))
	_user_dir = OS.get_user_data_dir()
	_remove_tree(_user_dir)
	DirAccess.make_dir_recursive_absolute(_user_dir)


## Copy every entry of `source` into `user://saves`, recursively. Returns the
## number of FILES copied.
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
