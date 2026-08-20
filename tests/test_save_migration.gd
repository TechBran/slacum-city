extends SimTest
## Doc 08 §2.8 read from the only direction that matters on release day: a save
## that is already on somebody's phone.
##
## `game/save_service.gd` shipped format 1 — one flat
## `{"format":1,"meta":{…},"ui":{…},"state":{…}}` file per slot, written into
## `user://saves/slot_N.json`. The doc 08 unification replaced that storage with
## a generation ladder. Every one of those files must still open, and the proof
## has to be a REAL one: `tests/fixtures/legacy_slot_format1.json` is a byte-for
## -byte capture of a format-1 write, produced by the shipped code before the
## change, and it is never regenerated. A fixture that is re-emitted by the new
## writer proves nothing at all.
##
## The fixture holds a seed-4242 city advanced five hours with one player-placed
## house, and a `ui` section with the onboarding flag set — the exact three
## things a returning player would lose if this path were wrong: their city,
## their progress, and their finished tutorial.

const FIXTURE := "res://tests/fixtures/legacy_slot_format1.json"
const TEST_DIR := "user://test_saves/migration"
## The fixture was captured from slot 3; the reader must not care, so it is
## installed somewhere else.
const TARGET_SLOT := 1


## Listing first, deleting second: removing entries inside a `list_dir_begin()`
## walk skips the ones after them, and a leftover slot would make a migration
## test pass on a file it did not install.
static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var files: Array[String] = []
	var dirs: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for child in files:
		DirAccess.remove_absolute(path + "/" + child)
	for child in dirs:
		_wipe(path + "/" + child)
		DirAccess.remove_absolute(path + "/" + child)


func _fresh_service() -> SaveService:
	var service := SaveService.new()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_wipe(TEST_DIR)
	service.base_dir = TEST_DIR
	return service


## Copy the fixture in, byte for byte, as the player's file.
func _install_legacy(service: SaveService, slot: int) -> int:
	var bytes := FileAccess.get_file_as_bytes(FIXTURE)
	var out := FileAccess.open("%s/slot_%d.json" % [TEST_DIR, slot], FileAccess.WRITE)
	out.store_buffer(bytes)
	out.flush()
	out = null
	return bytes.size()


## The format-1 reader, written out longhand. Comparing against this rather than
## against a recorded hash is deliberate: a hard-coded hash would fail every
## time the sim legitimately changed shape, and would then be "fixed" by
## re-recording it, which is how a migration test quietly stops testing.
func _reference_restore(seed_value: int) -> CitySim:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var envelope: Dictionary = parsed
	var sim := CitySim.boot_from_files(seed_value)
	sim.restore_state(envelope["state"])
	return sim


func test_a_format_1_file_still_loads() -> void:
	var service := _fresh_service()
	var bytes := _install_legacy(service, TARGET_SLOT)
	assert_true(bytes > 1000, "the fixture is a whole city (%d bytes)" % bytes)

	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, TARGET_SLOT),
			"the player's existing save opens: " + service.last_error)
	assert_eq(service.last_load_format, SaveService.LEGACY_FORMAT_VERSION,
			"…and the service knows which reader answered")
	assert_eq(restored.state_hash(), _reference_restore(4242).state_hash(),
			"the new reader produces exactly the city the old one did")
	assert_eq(restored.buildings.size(), 35, "the placed house survived the upgrade")

	# And it is still a live city, not a frozen snapshot: it advances in step
	# with the reference, which is the property a save exists to provide.
	var reference := _reference_restore(4242)
	restored.advance_hours(3.0)
	reference.advance_hours(3.0)
	assert_eq(restored.state_hash(), reference.state_hash(),
			"…and stays identical once time moves again")
	service.free()


func test_a_format_1_slot_lists_without_deserializing() -> void:
	# The load screen must show a pre-upgrade save the same way it shows any
	# other — the meta-first header is exactly what format 1 put in its first
	# bytes, and the legacy reader still reads it from there.
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	var slots := service.list_slots()
	assert_eq(slots.size(), 1)
	var meta: Dictionary = slots[0]
	assert_eq(int(meta["slot"]), TARGET_SLOT, "the file name is the authority on identity")
	assert_true(meta.has_all(["slot", "saved_at_unix", "day_index",
			"population", "treasury"]), "the documented header keys are all there")
	assert_eq(int(meta["format"]), SaveService.LEGACY_FORMAT_VERSION)
	assert_eq(int(meta["population"]), 148, "the captured city's population")
	assert_eq(int(meta["treasury"]), 25486)
	assert_true(service.has_slot(TARGET_SLOT))
	assert_eq(service.latest_slot(), TARGET_SLOT,
			"and a plain launch resumes it, exactly as before")
	service.free()


func test_the_ui_section_survives_the_format_change() -> void:
	# Doc 12 §2.17 through doc 08's envelope: a player who finished the tutorial
	# before the upgrade must not be shown it again after.
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	assert_true(service.load_slot(CitySim.boot_from_files(4242), TARGET_SLOT))
	var ui := service.last_loaded_ui
	assert_eq(bool((ui.get("onboarding", {}) as Dictionary).get("finished", false)), true,
			"the finished tutorial came back")
	assert_eq(String(ui.get("overlay", "")), "power", "…and so did the overlay choice")
	service.free()


func test_the_first_save_after_an_upgrade_writes_a_ladder() -> void:
	# The upgrade is lazy by design: reading a format-1 file leaves it EXACTLY
	# as found, so it is its own `pre_migration` checkpoint (doc 08 §2.7) at
	# zero cost and zero risk. The next save writes generation 1 beside it, and
	# from then on the ladder is the slot.
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	var legacy_path := "%s/slot_%d.json" % [TEST_DIR, TARGET_SLOT]
	var legacy_bytes := FileAccess.get_file_as_bytes(legacy_path)
	var sim := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(sim, TARGET_SLOT))
	assert_eq(FileAccess.get_file_as_bytes(legacy_path), legacy_bytes,
			"a load never rewrites the player's file")

	sim.advance_hours(1.0)
	assert_false(service.save_slot(sim, TARGET_SLOT).is_empty())
	assert_true(FileAccess.file_exists(
			"%s/slot_%d/gen_000001.sav" % [TEST_DIR, TARGET_SLOT]),
			"the next save is a generation")
	assert_eq(FileAccess.get_file_as_bytes(legacy_path), legacy_bytes,
			"…and the pre-upgrade file is still untouched behind it")
	assert_eq(service.list_slots().size(), 1,
			"one slot, not two — the ladder shadows the file it replaced")
	assert_eq(int(service.list_slots()[0]["format"]), SaveService.FORMAT_VERSION,
			"and the header says which format answered")

	var reloaded := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(reloaded, TARGET_SLOT))
	assert_eq(service.last_load_format, SaveService.FORMAT_VERSION,
			"the ladder wins over the file it superseded")
	assert_eq(reloaded.state_hash(), sim.state_hash())
	service.free()


func test_deleting_an_upgraded_slot_takes_both_copies() -> void:
	# Otherwise "delete this city" would leave the pre-upgrade city behind, and
	# the next launch would resume the thing the player just deleted.
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	var sim := CitySim.boot_from_files(4242)
	service.load_slot(sim, TARGET_SLOT)
	service.save_slot(sim, TARGET_SLOT)
	assert_true(service.delete_slot(TARGET_SLOT))
	assert_false(service.has_slot(TARGET_SLOT))
	assert_false(FileAccess.file_exists("%s/slot_%d.json" % [TEST_DIR, TARGET_SLOT]),
			"the format-1 file went with it")
	assert_false(DirAccess.dir_exists_absolute("%s/slot_%d" % [TEST_DIR, TARGET_SLOT]),
			"and so did the generation directory, quarantine and all")
	assert_eq(service.list_slots().size(), 0)
	service.free()


func test_the_pre_upgrade_file_is_the_ladder_s_last_candidate() -> void:
	# Doc 08 §2.9's walk ends at a directory scan. The format-1 file is one step
	# past that: a pinned checkpoint older than every generation. If the whole
	# ladder is unreadable, the difference for the player is "your city is gone"
	# versus "your city is back to before the update".
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	var sim := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(sim, TARGET_SLOT))
	var legacy_hash := sim.state_hash()
	sim.advance_hours(2.0)
	service.save_slot(sim, TARGET_SLOT)
	assert_ne(sim.state_hash(), legacy_hash, "the ladder holds a newer city")

	# Ruin every generation in the slot.
	var dir := DirAccess.open("%s/slot_%d" % [TEST_DIR, TARGET_SLOT])
	dir.list_dir_begin()
	var entry := dir.get_next()
	var ruined := 0
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("gen_"):
			var out := FileAccess.open_compressed(
					"%s/slot_%d/%s" % [TEST_DIR, TARGET_SLOT, entry],
					FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
			out.store_string("{\"schema_version\":1,\"body_sha256\":\"x\",\"body\":{}}")
			out = null
			ruined += 1
		entry = dir.get_next()
	dir.list_dir_end()
	assert_true(ruined > 0, "there was something to ruin")

	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, TARGET_SLOT),
			"the pre-upgrade file is still there and still loads")
	assert_eq(restored.state_hash(), legacy_hash, "…and it is the pre-upgrade city")
	assert_true(service.last_load_recovered, "reported as a recovery, not a normal load")
	assert_eq(service.last_load_format, SaveService.LEGACY_FORMAT_VERSION)
	assert_eq(service.last_error, "", "a recovery is not a failure")
	service.free()


func test_a_save_from_a_newer_build_is_refused_not_half_read() -> void:
	# Doc 08 §2.8's downgrade rule, on the legacy reader: a sideloaded older APK
	# meeting a newer file must refuse and leave the file alone, never restore
	# half of it.
	var service := _fresh_service()
	_install_legacy(service, TARGET_SLOT)
	var path := "%s/slot_%d.json" % [TEST_DIR, TARGET_SLOT]
	var text := FileAccess.get_file_as_string(path)
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(text.replace("{\"format\":1,", "{\"format\":99,"))
	out = null
	var victim := CitySim.boot_from_files(4242)
	var before := victim.state_hash()
	assert_false(service.load_slot(victim, TARGET_SLOT))
	assert_eq(service.last_error, "downgrade")
	assert_eq(victim.state_hash(), before, "nothing was restored")
	assert_true(FileAccess.file_exists(path), "and the file was not touched")
	service.free()


func test_an_upgrading_phone_still_finds_the_shadow_it_arrived_with() -> void:
	# The retired rotation left TWO format-1 files on every device that ran it,
	# and the newer half is as likely to be the shadow as the primary. Losing
	# track of it would cost an upgrading player one autosave interval on their
	# first unclean launch — the exact interval the rotation existed to save.
	var service := _fresh_service()
	_install_legacy(service, SaveService.AUTOSAVE_SLOT)
	_install_legacy(service, SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT)
	# Stamp the shadow newer, which is what the alternation would have left
	# behind half the time.
	var shadow_path := "%s/slot_%d.json" % [TEST_DIR, SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT]
	var text := FileAccess.get_file_as_string(shadow_path)
	var out := FileAccess.open(shadow_path, FileAccess.WRITE)
	out.store_string(text.replace("\"saved_at_unix\":1787191369",
			"\"saved_at_unix\":1787999999"))
	out = null

	assert_eq(service.last_good_autosave_slot(),
			SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT,
			"the newer half is the right offer, wherever it landed")
	var sentinel := CrashSentinel.new()
	sentinel.runtime_dir = TEST_DIR + "/runtime"
	sentinel.logs_dir = TEST_DIR + "/logs"
	assert_eq(sentinel.recovery_slot(service),
			SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT,
			"…and the sentinel's contract is answered unchanged across the upgrade")

	# One autosave later the ladder owns the answer and the shadow is history.
	var sim := CitySim.boot_from_files(4242)
	service.load_slot(sim, SaveService.LEGACY_AUTOSAVE_SHADOW_SLOT)
	service.autosave(sim)
	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"the ladder answers from here on")
	assert_eq(service.last_autosave_slot, SaveService.AUTOSAVE_SLOT,
			"and nothing alternates any more")
	service.free()


# --------------------------------------------------- doc 08 §7 test 37 (G-7)

func test_37_bench_city_is_a_boot_file_that_round_trips_the_save_path() -> void:
	# **Ruling.** Doc 08 §7 test 37 asked whether `tests/fixtures/bench_city.json`
	# "loads under the current registry and passes `validate_structural()`". It
	# cannot, and it should not: the fixture is a BOOT file in
	# `data/starter_city.json`'s shape — blocks, buildings, roads — not a save
	# body. Doc 09 §2.13 called it a save file; that was the error. Feeding it to
	# the save loader would test nothing except that two unrelated schemas
	# disagree.
	#
	# Report G-7's actual requirement — "doc 11's on-device gates cannot silently
	# stop running against a stale fixture" — is met by validating it as what it
	# is, and then by putting the city it produces THROUGH the save path. That
	# second leg is the one that catches a save-schema drift, and it catches it
	# on 1,500 buildings rather than on the starter city's 35.
	var boot: Dictionary = StarterCityLoader.read_json(
			"res://tests/fixtures/bench_city.json")
	assert_false(boot.is_empty(), "the fixture parses")
	var starter: Dictionary = StarterCityLoader.read_json("res://data/starter_city.json")
	assert_eq(int(boot.get("schema_version", -1)), int(starter.get("schema_version", -2)),
			"it tracks the BOOT file's schema version, not the save envelope's")

	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"), boot,
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	assert_eq(str(sim.boot_errors), str(PackedStringArray()), "and boots clean")
	assert_eq(sim.buildings.size(), 1500)

	var service := _fresh_service()
	var meta := service.save_slot(sim, 2)
	assert_false(meta.is_empty(), "1,500 buildings commit: " + service.last_error)
	var restored := CitySim.new()
	restored.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"), boot,
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	assert_true(service.load_slot(restored, 2), "…and load back: " + service.last_error)
	assert_eq(restored.state_hash(), sim.state_hash(),
			"the benchmark city survives the save path bit-identically")
	assert_eq(str(service.repair_notes), str(PackedStringArray()),
			"with zero structural repairs — the registry and the body agree")
	sim.scheduler.dispose()
	restored.scheduler.dispose()
	service.free()
