extends SceneTree
## **What a REAL city collects** — doc 03 §2.5a's back-pay, run against an actual
## generation file rather than a synthetic body (Wave 24, doc 92 §63.5).
##
##   ~/.local/bin/godot --headless --path . -s res://tools/measure_backpay.gd \
##       -- --file=/abs/path/gen_000291.sav
##
## It reads the file, runs doc 08 §2.8's real migrator at the section version the
## body carries, restores into a real `CitySim`, and prints the ledger either
## side of the settlement. Then it re-captures the restored city and loads THAT,
## which is the second-load proof: a feature that pays on every load has to be
## shown paying nothing on the second one, on the same city, not on a fixture.
##
## Read-only with respect to the file and to `user://`: it opens the path it is
## given, never writes, and never touches a save slot.

const CITY_SECTION := "city"


func _initialize() -> void:
	var path := ""
	for raw: Variant in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--file="):
			path = arg.substr(7)
	if path == "":
		printerr("measure_backpay: --file=PATH is required")
		quit(2)
		return
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		printerr("measure_backpay: cannot open %s" % path)
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("measure_backpay: body is not a JSON object")
		quit(2)
		return
	var envelope: Dictionary = parsed
	var body: Dictionary = envelope.get("body", envelope)
	var city: Dictionary = body.get(CITY_SECTION, {})
	if city.is_empty():
		printerr("measure_backpay: no `city` section in %s" % path)
		quit(2)
		return
	var from_version := int(city.get("section_version", 1))
	print("file           %s" % path)
	print("city section   version %d  (this build writes %d)"
			% [from_version, CitySim.SAVE_SECTION_VERSION])
	var goals: Dictionary = city.get("goals", {})
	var progression: Dictionary = city.get("progression", {})
	var treasury_block: Dictionary = city.get("treasury", {})
	print("earned_level   %d" % int(goals.get("earned_level", 0)))
	print("city_level     %d" % int(progression.get("city_level", 0)))
	print("treasury       $%d" % int(treasury_block.get("treasury", 0)))
	print("ledger in file %s"
			% str(treasury_block.get("grant_paid_by_level", "(none — legacy)")))

	var sim := CitySim.boot_from_files(1337)
	var migrated: Dictionary = sim.migrate_save_section(city.duplicate(true),
			from_version)
	print("stamp          grant_ledger_bootstrap = %s"
			% str((migrated["treasury"] as Dictionary).get("grant_ledger_bootstrap",
					"(none)")))
	sim.bus.drain()
	sim.restore_state(migrated)
	_report(sim, "FIRST LOAD")

	# The second-load proof, on the city the first load produced.
	var written: Dictionary = sim.capture_state().duplicate(true)
	var again := CitySim.boot_from_files(1337)
	again.bus.drain()
	again.restore_state(written)
	_report(again, "SECOND LOAD")
	print("")
	print("balance after first load   $%d" % sim.treasury.balance)
	print("balance after second load  $%d" % again.treasury.balance)
	print("second load paid           $%d"
			% (again.treasury.balance - sim.treasury.balance))
	quit(0)


func _report(sim: CitySim, label: String) -> void:
	print("")
	print("--- %s" % label)
	var receipt: Dictionary = {}
	for entry: Variant in sim.bus.drain():
		var event: Dictionary = entry
		if String(event.get("type", "")) == "level_up_grant_arrears_paid":
			receipt = event
	if receipt.is_empty():
		print("  receipt      (none — nothing was owed)")
	else:
		print("  receipt      levels %s" % str(receipt.get("levels", [])))
		print("               amounts %s" % str(receipt.get("amounts", [])))
		print("               total $%d" % int(receipt.get("amount", 0)))
	var ladder: Array = []
	for level in range(0, sim.econ_curves.top_level_up_grant_level() + 1):
		ladder.append(sim.treasury.grant_paid(level))
	print("  ledger       %s" % str(ladder))
	print("  earned_level %d   city_level %d"
			% [sim.goals.earned_level, sim.progression.city_level])
	print("  treasury     $%d   deferred $%d"
			% [sim.treasury.balance, sim.treasury.deferred_liability])
