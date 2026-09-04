extends SceneTree
## Wave-23 instrument (doc 92 §62.6). **IS OWNING A FIRE DEPARTMENT WORTH IT?**
##
## Doc 93 §AV1 corrected the predicate that decides whether an unanswerable fire
## condemns or destroys, and the correction sharpens a question Wave 21 left
## open and its own verifier answered the wrong way round: with the protection
## keyed on NOT having a service, a city that owned a fire department was
## measurably WORSE off than one that did not — 66 buildings alive against 68,
## plus the department's upkeep. A game that pays you for not building the fire
## station has inverted its own lesson.
##
## This tool is the A/B that settles it, and it is deliberately a DIFFERENT rig
## from `tools/measure_player_city.gd`. That one loads a real terminal save whose
## roads are gone, whose treasury is pinned at the credit floor and where the
## restore agent saturates: three arms there come out tied on both of the numbers
## the question is about, because neither can move. **A city that has already
## fallen cannot answer "should I buy a fire station?".** So this boots a HEALTHY
## founding city and asks it there, on the two numbers the ruling is judged on —
## buildings alive and treasury — plus the incident count that explains them.
##
##   ~/.local/bin/godot --headless --path <repo> \
##       -s res://tools/measure_fire_incentive.gd -- [opts]
##
##   --days=N       game-days to advance in each arm (default 90)
##   --seed=N       RNG seed (default 1337)
##   --arms=a,b     which arms to run (default keep,burn,none)
##   --preset=NAME  difficulty preset (default the shipped default)
##
## THE THREE ARMS, which differ in the fire department and in nothing else:
##
##   keep — every `fire_station` is pinned at condition 1.0 every game-hour, so
##          the department can never wear out. This is the player who maintains.
##   burn — the founding department, untouched: it wears, it can be damaged, and
##          nobody repairs it. This is the player who bought one and forgot it.
##   none — the department is BULLDOZED at hour 0 through the real
##          `cmd_demolish_building`, which refunds construction money and retires
##          its engines (`FleetSystem.remove_station`). Under §AV1 that is the
##          one door in the game that ends a service, and the arm is deliberately
##          given the refund: if `keep` still wins against an arm that was PAID
##          to divest, the inequality is not an artefact of the accounting.
##
## It is a MEASURING instrument (constitution §3): it boots the real `CitySim`,
## owns no constant, and is never imported by `sim/`.

const HOURS_PER_DAY := 24
const ARMS := ["keep", "burn", "none"]


func _initialize() -> void:
	var days := 90
	var seed_value := 1337
	var arms: Array[String] = []
	var preset := Difficulty.DEFAULT_PRESET
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="):
			days = int(arg.substr(7))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--preset="):
			preset = arg.substr(9)
		elif arg.begins_with("--arms="):
			for piece in arg.substr(7).split(",", false):
				arms.append(String(piece))
	if arms.is_empty():
		for arm in ARMS:
			arms.append(String(arm))

	print("measure_fire_incentive: seed %d, preset %s, %d game-days, arms %s"
			% [seed_value, preset, days, ", ".join(arms)])
	var rows: Array[Dictionary] = []
	for arm in arms:
		rows.append(_run_arm(String(arm), days, seed_value, preset))

	print("")
	print("  arm  | alive | treasury | condemned | incidents | fires | destroyed"
			+ " | pop | E_dept/gh")
	for row in rows:
		print("  %-4s | %5d | %8d | %9d | %9d | %5d | %9d | %3d | %.2f" % [
			String(row["arm"]), int(row["alive"]), int(row["treasury"]),
			int(row["condemned"]), int(row["incidents"]), int(row["fires"]),
			int(row["destroyed"]), int(row["population"]),
			float(row["departments"])])
	print("")
	_verdict(rows)
	quit(0)


## One arm, start to finish, in its own `CitySim`. Nothing is shared between
## arms but the seed and the city file, which is what makes the deltas
## attributable to the department alone.
func _run_arm(arm: String, days: int, seed_value: int, preset: String) -> Dictionary:
	var sim := CitySim.boot_from_files(seed_value, preset)
	if arm == "none":
		_bulldoze_every_fire_department(sim)
	var created := 0
	var fires := 0
	var destroyed := 0
	for h in days * HOURS_PER_DAY:
		if arm == "keep":
			_pin_fire_departments(sim)
		sim.scheduler.advance_coarse_n(1)
		for event in sim.bus.drain():
			var type := String(event["type"])
			if type == "incident_created":
				created += 1
				if String(event.get("incident_type", "")) == "structure_fire":
					fires += 1
			elif type == "building_destroyed":
				destroyed += 1
	var alive := 0
	var condemned := 0
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.state == &"destroyed":
			continue
		alive += 1
		if b.state == &"damaged" \
				and b.condition <= b.rule("structural_failure_threshold") + 0.0001:
			condemned += 1
	var row := {
		"arm": arm,
		"alive": alive,
		"condemned": condemned,
		"treasury": int(sim.treasury.balance),
		"incidents": created,
		"fires": fires,
		"destroyed": destroyed,
		"population": int(sim.population.city_population),
		"departments": _departments_expense(sim),
		"capability": sim.incident_world.has_fire_capability(),
	}
	print("  arm %-4s: alive %d, treasury $%d, incidents %d (fires %d),"
			% [arm, alive, int(sim.treasury.balance), created, fires]
			+ " condemned %d, destroyed %d, fire capability %s"
			% [condemned, destroyed, str(row["capability"])])
	sim.dispose()
	return row


## The player's own bulldoze, through the real command: the refund is paid, the
## shell comes off the map and `FleetSystem.remove_station` retires the engines.
func _bulldoze_every_fire_department(sim: CitySim) -> void:
	for id in sim.roster_ids().duplicate():
		var b: Building = sim.buildings[id]
		if b.archetype == &"fire_station":
			sim.cmd_demolish_building(String(id), false)


## The `keep` arm's pin: a department that can never wear out, so the delta
## between `keep` and `burn` is maintenance and nothing else.
func _pin_fire_departments(sim: CitySim) -> void:
	for id in sim.roster_ids():
		var b: Building = sim.buildings[id]
		if b.archetype != &"fire_station":
			continue
		if b.state == &"damaged" or b.state == &"repairing":
			b.state = &"active"
		b.condition = 1.0


## Doc 03 §2.4's `E_departments` for the last settled game-hour — what the
## department actually costs, read out of the settlement rather than retyped.
func _departments_expense(sim: CitySim) -> float:
	var settled: Dictionary = sim.last_settlement
	if settled.is_empty():
		return 0.0
	return float((settled.get("expenses", {}) as Dictionary).get("departments", 0.0))


## The gate, stated as an inequality and checked rather than asserted in prose:
## owning and keeping the department must be the best arm on buildings alive and
## on treasury.
func _verdict(rows: Array[Dictionary]) -> void:
	var by_arm := {}
	for row in rows:
		by_arm[String(row["arm"])] = row
	if not (by_arm.has("keep") and by_arm.has("none")):
		print("  (verdict needs both the keep and the none arm)")
		return
	var keep: Dictionary = by_arm["keep"]
	var none: Dictionary = by_arm["none"]
	print("  VERDICT keep vs none: alive %+d, treasury %+d, incidents %+d" % [
			int(keep["alive"]) - int(none["alive"]),
			int(keep["treasury"]) - int(none["treasury"]),
			int(keep["incidents"]) - int(none["incidents"])])
	var wins_alive := int(keep["alive"]) >= int(none["alive"])
	var wins_money := int(keep["treasury"]) >= int(none["treasury"])
	print("  owning and keeping the department is the best arm: %s"
			% str(wins_alive and wins_money)
			+ " (alive %s, treasury %s)" % [str(wins_alive), str(wins_money)])
