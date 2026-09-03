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


# ============================ the city section's own ladder: v1 → v2 (Wave 8)
#
# Doc 08 §2.8 gives every SECTION a version independent of the envelope's. The
# `city` section moved to **2** when dispatch ETAs became street-true and the
# fire-spread breakpoint became conditional (doc 08 §2.8's dated note, and
# `CitySim.SAVE_SECTION_VERSION`'s own docstring). Both changes alter what the
# binary does NEXT with a body; neither adds, removes or renames a field.
#
# That makes this the awkward migration to test, and the interesting one: a
# shape migration announces itself the moment a key is missing, whereas an
# identity migrator that is silently never called looks exactly like one that
# ran. So the tests below check the LADDER WAS WALKED, not merely that the city
# came back.


## Rewrite the newest generation in `slot` with the `city` section stamped at
## `version`, reproducing `SaveManager.request_save`'s envelope byte for byte:
## the body is re-stringified with the same flags, the digest is taken over that
## exact text, and the envelope is concatenated so the hashed bytes ARE the
## embedded bytes (doc 08 §2.6 step 3). Anything less and the load gate would
## reject the file for a bad digest and the test would pass for the wrong reason.
func _restamp_city_section(service: SaveService, slot: int, version: int) -> void:
	var manager := service.manager_for(slot)
	var file_name := String((manager.read_manifest()["active"] as Dictionary)["file"])
	var path := service.slot_dir(slot) + "/" + file_name
	var reader := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	assert_true(reader != null, "the generation just written is readable")
	var envelope: Dictionary = JSON.parse_string(reader.get_as_text())
	reader = null
	var body: Dictionary = envelope["body"]
	var city: Dictionary = body[String(SaveService.CITY_SECTION)]
	assert_eq(int(city["section_version"]), CitySim.SAVE_SECTION_VERSION,
			"the writer stamped the section it claims to be on")
	city["section_version"] = version
	var body_text := JSON.stringify(body, "", true, true)
	var text := "{\"schema_version\":%d,\"body_sha256\":\"%s\",\"body\":%s}" % [
			int(envelope["schema_version"]), _sha256_of(body_text), body_text]
	var out := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out.flush()
	out = null


static func _sha256_of(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()


func test_the_city_section_is_on_rung_nine() -> void:
	# The constant, the published accessor and the bytes on disk must agree.
	# A bump that lands in only two of the three is how a save silently keeps
	# claiming to be something it is not.
	#
	# **Rung 9, Wave 19** (report 98 §60 RR-170): doc 03 §2.5b's commissions
	# board adds one top-level key, `contracts`, and one entry inside an existing
	# one, `rng.contracts` — the same two shapes rung 7 added for the street
	# layer, and `_v8_to_v9` is the identity function for the same reason
	# `_v6_to_v7` was: an absent block deserialises to an empty board, which is
	# what a city that has never seen the board should restore to.
	assert_eq(CitySim.SAVE_SECTION_VERSION, 9,
			"the commissions board is rung 9 (doc 08 §2.8, report 98 §60 RR-170)")
	var sim := CitySim.boot_from_files(4242)
	assert_eq(sim.save_section_version(), CitySim.SAVE_SECTION_VERSION)
	var service := _fresh_service()
	service.save_slot(sim, TARGET_SLOT)
	var manager := service.manager_for(TARGET_SLOT)
	var file_name := String((manager.read_manifest()["active"] as Dictionary)["file"])
	var reader := FileAccess.open_compressed(
			service.slot_dir(TARGET_SLOT) + "/" + file_name,
			FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var envelope: Dictionary = JSON.parse_string(reader.get_as_text())
	reader = null
	assert_eq(int(((envelope["body"] as Dictionary)[String(SaveService.CITY_SECTION)]
			as Dictionary)["section_version"]), CitySim.SAVE_SECTION_VERSION,
			"the file on disk carries the rung, not just the class")
	service.free()


func test_a_v1_city_section_still_loads_and_is_the_same_city() -> void:
	# The player's side of the epoch. Because v2 changed no shape, a v1 body IS
	# the bytes v2 writes — so restamping the section version is a faithful
	# forgery of a save from the previous build, and the whole city has to come
	# back out of it: every building, every dollar, every RNG stream.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(2.0)
	var expected := sim.state_hash()
	service.save_slot(sim, TARGET_SLOT)
	_restamp_city_section(service, TARGET_SLOT, 1)

	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, TARGET_SLOT),
			"a pre-epoch save opens: " + service.last_error)
	assert_eq(restored.state_hash(), expected,
			"…and it is the same city, to the bit")
	assert_eq(str(service.repair_notes), str(PackedStringArray()),
			"with no structural repairs — v1 and v2 are the same shape")
	# And it is a LIVE city under the NEW rules: two instances that both arrived
	# from a v1 body advance together. (They cannot match a v1 binary — that is
	# what the epoch records — but they must match each other, which is what
	# save/load identity means.)
	var twin := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(twin, TARGET_SLOT))
	restored.advance_hours(3.0)
	twin.advance_hours(3.0)
	assert_eq(restored.state_hash(), twin.state_hash(),
			"save → load → advance is identical within the v2 rules")
	service.free()


func test_the_v1_body_goes_through_the_migrator_rather_than_around_it() -> void:
	# The identity-migrator trap: `restore_state` would have produced the right
	# city whether or not the ladder ran, so "the city came back" proves nothing
	# about the ladder. This asserts the call itself, on a probe registered under
	# the city key, and then asserts the real migrator's contract separately.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(4242)
	service.save_slot(sim, TARGET_SLOT)
	_restamp_city_section(service, TARGET_SLOT, 1)
	var probe := LadderProbe.new()
	assert_true(service.load_slot(probe, TARGET_SLOT), service.last_error)
	assert_eq(probe.migrated_from, 1,
			"the section ladder was walked from the rung the file claims")
	assert_true(probe.restored.has("clock"), "and the body arrived intact")
	service.free()


func test_the_city_section_ladder_is_total_and_additive_only() -> void:
	# Doc 08 §2.8's rules on the real thing.
	#
	# **TOTAL**: it may not fail, whatever it is handed — an empty body, a body
	# from a version that does not exist, a body already on the current rung.
	#
	# **ADDITIVE-FIRST**: v1 → v2 marks a rules epoch and is the identity; v2 → v3
	# (Wave 9, doc 09 §2.14.4) adds **exactly one** key, `goals`, and touches
	# nothing else; v3 → v4 (the routing/cadence epoch), v4 → v5 (the
	# upgrade-timing epoch) and v5 → v6 (the difficulty epoch) are rules rungs and
	# identities again. v6 in particular adds no TOP-LEVEL key at all: the preset
	# it names already lives in the `director` section, and a body with no
	# director section is a fragment rather than a city. A migrator that quietly
	# "fixed" something here would be rewriting the player's city on load, and no
	# rung on this ladder does.
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(1.0)
	var body := sim.canonical_capture()
	var keys_before := body.keys().size()
	# A body written by THIS build already carries its `goals` block, so the whole
	# ladder is the identity on it — which is the property that matters for a
	# restamped-v1 forgery of a save from the previous build.
	var migrated := sim.migrate_save_section(body, 1)
	assert_eq(migrated.keys().size(), keys_before, "no key was added or dropped")
	assert_eq(JSON.stringify(migrated, "", true, true),
			JSON.stringify(body, "", true, true),
			"the ladder is the identity on a body that is already whole")
	# A genuine v2 body has no `goals` block at all, and the rung adds one — the
	# MARKER, never an answer: doc 08 §2.8 forbids a migrator from reading
	# `data/`, and the curriculum lives in `data/goals.json`.
	var v2_body := sim.canonical_capture()
	v2_body.erase("goals")
	var lifted := sim.migrate_save_section(v2_body, 2)
	assert_eq(lifted.keys().size(), keys_before,
			"v2 → v3 adds exactly the one key it removed")
	assert_true(bool((lifted["goals"] as Dictionary).get("bootstrap", false)),
			"and what it adds is the bootstrap marker, not a fabricated answer")
	# Totality, on the inputs a real ladder meets. Compared field by field rather
	# than with `==`, because Dictionary equality is not the assertion this test
	# wants to be relying on.
	var empty := sim.migrate_save_section({}, 1)
	assert_eq(empty.keys().size(), 1,
			"an empty body migrates rather than failing, and gains only the marker")
	assert_true(empty.has("goals"))
	assert_eq(int(sim.migrate_save_section({"a": 1},
			CitySim.SAVE_SECTION_VERSION).get("a", 0)), 1,
			"a body already on the current rung is left alone")
	assert_eq(sim.migrate_save_section({"a": 1},
			CitySim.SAVE_SECTION_VERSION).keys().size(), 1)
	# …and the rungs ABOVE v3 are identities, so a body that only ever sees them
	# comes out byte-identical however many of them it walks. This is the
	# assertion that would catch a v4 → v5 (or later) rung that quietly started
	# inventing a key: the goals marker is the ONLY thing this ladder may add.
	assert_eq(sim.migrate_save_section({"a": 1}, 4).keys().size(), 1,
			"v4 → v5 → v6 → v7 are identities: no epoch adds a top-level key")
	# The one thing v6 DOES write, and where: inside a director section that
	# exists but does not name its preset.
	var unnamed := sim.migrate_save_section({"director": {"tp_pool": 3.0}}, 5)
	assert_eq(unnamed.keys().size(), 1, "still no new top-level key")
	assert_eq(String((unnamed["director"] as Dictionary)["difficulty"]),
			Difficulty.DEFAULT_PRESET,
			"v5 → v6 names the preset the body was actually played on")
	# v6 → v7 (the opportunity layer, doc 06 §2.16) is an identity too, and it is
	# the interesting one to say out loud: it adds a `street` section and a
	# seventh RNG stream to the SHAPE, and still writes nothing here, because a
	# v6 body's absent `street` block and unknown `street` stream both restore to
	# exactly what a v6 city had — an empty street on its boot seed.
	assert_eq(sim.migrate_save_section({"a": 1}, 6).keys().size(), 1,
			"v6 → v7 invents no key: restore_state answers the absent section")
	assert_eq(int(sim.migrate_save_section({"a": 1}, 8).get("a", 0)), 1,
			"a body from the future is not mangled on the way past")
	# And a body restored through the migrator is the body itself.
	var restored := CitySim.boot_from_files(4242)
	restored.restore_state(sim.migrate_save_section(sim.canonical_capture(), 1))
	assert_eq(restored.state_hash(), sim.state_hash())


## Registered under the `city` key like `CitySim` is, but it records the ladder
## call instead of being a city. Same duck-typed contract `SaveService` reads.
class LadderProbe extends RefCounted:
	var restored: Dictionary = {}
	var migrated_from: int = -1

	func canonical_capture() -> Dictionary:
		return {"clock": {"tick": 0}}

	func restore_state(body: Dictionary) -> void:
		restored = body

	func save_section_version() -> int:
		return CitySim.SAVE_SECTION_VERSION

	func migrate_save_section(data: Dictionary, from_version: int) -> Dictionary:
		migrated_from = from_version
		return data


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
