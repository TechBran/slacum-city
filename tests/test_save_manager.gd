extends SimTest
## Doc 08 §2.5–2.9: envelope, atomic commit, retention ladder, load gate,
## corruption fallback, section migration.


class FakeSection extends SaveSection:
	var key: StringName
	var version: int
	var payload: Dictionary = {}
	var restored: Dictionary = {}
	var migrated_from: int = -1

	func _init(p_key: StringName, p_version: int = 1) -> void:
		key = p_key
		version = p_version

	func section_key() -> StringName:
		return key

	func section_version() -> int:
		return version

	func serialize() -> Dictionary:
		return payload.duplicate(true)

	func deserialize(data: Dictionary) -> void:
		restored = data

	func migrate_section(data: Dictionary, from_version: int) -> Dictionary:
		migrated_from = from_version
		data["upgraded"] = true
		return data


static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			_wipe(path + "/" + entry)
			DirAccess.remove_absolute(path + "/" + entry)
		else:
			DirAccess.remove_absolute(path + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()


func _fresh(name: String) -> SaveManager:
	var dir := "user://test_saves/" + name
	_wipe(dir)
	return SaveManager.new(dir)


func test_save_load_roundtrip() -> void:
	var manager := _fresh("roundtrip")
	var economy := FakeSection.new(&"economy")
	economy.payload = {"treasury": 68000, "carry": 412}
	var power := FakeSection.new(&"power")
	power.payload = {"components": [1, 2, 3]}
	manager.register_section(economy)
	manager.register_section(power)
	var saved := manager.request_save("manual", 1000, 1_600_000)
	assert_true(bool(saved["ok"]))
	assert_eq(saved["payload"]["file"], "gen_000001.sav")

	var loader := SaveManager.new(manager.base_dir)
	var economy2 := FakeSection.new(&"economy")
	var power2 := FakeSection.new(&"power")
	loader.register_section(economy2)
	loader.register_section(power2)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	assert_false(bool(loaded["payload"]["recovered"]))
	# JSON round-trip delivers numbers as floats; sections cast on read
	# (SaveSection contract).
	assert_eq(int(economy2.restored["treasury"]), 68000)
	assert_eq(int(economy2.restored["carry"]), 412)
	var components: Array = power2.restored["components"]
	assert_eq(components.size(), 3)
	for i in 3:
		assert_eq(int(components[i]), i + 1)
	assert_eq(int(loaded["payload"]["body"]["sim_time_minutes"]), 1000)


func test_corrupted_active_falls_back_and_quarantines() -> void:
	var manager := _fresh("corrupt")
	var section := FakeSection.new(&"economy")
	section.payload = {"treasury": 100}
	manager.register_section(section)
	manager.request_save("autosave", 100, 1_600_000)
	section.payload = {"treasury": 200}
	manager.request_save("autosave", 200, 1_600_300)

	# Tamper with the newest generation: flip a byte inside the body so the
	# digest no longer matches.
	var path := manager.base_dir + "/gen_000002.sav"
	var file := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var text := file.get_as_text()
	file = null
	text = text.replace("\"treasury\":200", "\"treasury\":999")
	var out := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out = null

	var loader := SaveManager.new(manager.base_dir)
	var section2 := FakeSection.new(&"economy")
	loader.register_section(section2)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	assert_true(bool(loaded["payload"]["recovered"]), "fell back to a checkpoint")
	assert_eq(loaded["payload"]["file"], "gen_000001.sav")
	assert_eq(int(loaded["payload"]["lost_minutes"]), 100, "high water 200 − loaded 100")
	assert_eq(section2.restored["treasury"], 100)
	assert_true(FileAccess.file_exists(loader.base_dir + "/quarantine/bad_gen_000002.sav"),
			"tampered file quarantined, never deleted")


func test_downgrade_skipped_without_quarantine() -> void:
	var manager := _fresh("downgrade")
	var section := FakeSection.new(&"economy")
	section.payload = {"treasury": 100}
	manager.register_section(section)
	manager.request_save("autosave", 100, 1_600_000)

	# Hand-craft a "newer app" generation with a valid digest.
	var body := "{\"economy\":{\"section_version\":1,\"treasury\":5},\"schema_version\":99,\"sim_time_minutes\":150}"
	var digest: String = SaveManager._sha256(body)
	var text := "{\"schema_version\":99,\"body_sha256\":\"%s\",\"body\":%s}" % [digest, body]
	var out := FileAccess.open_compressed(manager.base_dir + "/gen_000009.sav",
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out = null

	var loader := SaveManager.new(manager.base_dir)
	var section2 := FakeSection.new(&"economy")
	loader.register_section(section2)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	assert_eq(loaded["payload"]["file"], "gen_000001.sav", "downgrade candidate skipped")
	assert_false(FileAccess.file_exists(loader.base_dir + "/quarantine/bad_gen_000009.sav"),
			"downgrade file is refused but never touched")
	assert_true(FileAccess.file_exists(loader.base_dir + "/gen_000009.sav"))


func test_missing_section_repaired_with_defaults() -> void:
	var manager := _fresh("repair")
	var economy := FakeSection.new(&"economy")
	economy.payload = {"treasury": 50}
	manager.register_section(economy)
	manager.request_save("autosave", 60, 1_600_000)

	var loader := SaveManager.new(manager.base_dir)
	var economy2 := FakeSection.new(&"economy")
	var late_arrival := FakeSection.new(&"weather")  # section added after the save
	loader.register_section(economy2)
	loader.register_section(late_arrival)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	assert_eq(late_arrival.restored, {"section_version": 1}, "defaults injected")
	assert_eq(loader.repair_notes.size(), 1)


func test_section_migration_runs() -> void:
	var manager := _fresh("secmig")
	var v1 := FakeSection.new(&"economy", 1)
	v1.payload = {"treasury": 10}
	manager.register_section(v1)
	manager.request_save("autosave", 10, 1_600_000)

	var loader := SaveManager.new(manager.base_dir)
	var v2 := FakeSection.new(&"economy", 2)
	loader.register_section(v2)
	var loaded := loader.load_newest()
	assert_true(bool(loaded["ok"]))
	assert_eq(v2.migrated_from, 1, "section ladder invoked from stored version")
	assert_true(bool(v2.restored.get("upgraded", false)))


func test_time_consistency_gate() -> void:
	var manager := _fresh("timegate")
	# sim_time_minutes must equal time.tick_index / 4 (constitution §4 amended).
	var body := "{\"schema_version\":1,\"sim_time_minutes\":100,\"time\":{\"section_version\":1,\"tick_index\":999}}"
	var digest: String = SaveManager._sha256(body)
	var text := "{\"schema_version\":1,\"body_sha256\":\"%s\",\"body\":%s}" % [digest, body]
	var out := FileAccess.open_compressed(manager.base_dir + "/gen_000001.sav",
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out = null
	var loaded := manager.load_newest()
	assert_false(bool(loaded["ok"]), "999 / 4 = 249 != 100 → structurally rejected")


func test_retention_ladder() -> void:
	var manager := _fresh("retention")
	var section := FakeSection.new(&"economy")
	manager.register_section(section)
	# Chronological saves; ages measured from the final active save.
	var times: Array[int] = [
		990_000, 1_300_000, 1_560_000, 1_600_000,
		1_603_000, 1_603_500, 1_603_560, 1_603_570,
	]
	for i in times.size():
		section.payload = {"treasury": (i + 1) * 100}
		manager.request_save("autosave", (i + 1) * 100, times[i])
	var manifest: Dictionary = manager.read_manifest()
	assert_eq(String(manifest["active"]["file"]), "gen_000008.sav")
	var kept_files: Array = []
	for entry in manifest["history"]:
		kept_files.append(String(entry["file"]))
	# B newest-other, C ≥30 min, D ≥6 h, E ≥24 h, F ≥7 d (doc 08 §2.7)
	assert_eq(kept_files, ["gen_000007.sav", "gen_000004.sav", "gen_000003.sav",
			"gen_000002.sav", "gen_000001.sav"])
	assert_false(FileAccess.file_exists(manager.base_dir + "/gen_000005.sav"), "swept")
	assert_false(FileAccess.file_exists(manager.base_dir + "/gen_000006.sav"), "swept")
	assert_true(FileAccess.file_exists(manager.base_dir + "/gen_000001.sav"), "week-deep slot kept")


func test_the_retention_ladder_is_data_not_code() -> void:
	# Doc 08 §8. The ladder used to be a `const` in this file, which is how the
	# project ended up with two writers disagreeing about how many saves to keep.
	var policy := SavePolicy.load_from_files()
	assert_true(policy.is_valid(), "data/persistence.json parses (%s)" % str(policy.errors))
	assert_eq(policy.max_unpinned_generations, 6, "doc 08 §2.7: 6 unpinned")
	assert_eq(policy.max_pinned_generations, 2, "…and 2 pinned")
	assert_eq(str(policy.history_slot_min_age_s), str(SaveManager.RETENTION_SLOT_MIN_AGE_S),
			"the data ladder and the code fallback say the same thing")
	assert_eq(policy.current_schema_version, SaveManager.CURRENT_SCHEMA_VERSION,
			"the documented envelope version matches the one this build writes — "
			+ "a tripwire, because the ladder that has to agree with it is code")

	# A shorter ladder keeps fewer generations, with no code change.
	var short_policy := SavePolicy.from_dict({"save": {
		"max_unpinned_generations": 2,
		"retention_slot_age_real_seconds": [0, 0],
	}})
	assert_eq(short_policy.history_slot_min_age_s.size(), 1)
	var manager := SaveManager.new("user://test_saves/shortladder", short_policy)
	_wipe(manager.base_dir)
	manager = SaveManager.new("user://test_saves/shortladder", short_policy)
	var section := FakeSection.new(&"economy")
	manager.register_section(section)
	for i in 5:
		manager.request_save("autosave", (i + 1) * 10, 1_600_000 + i * 10)
	assert_eq((manager.read_manifest()["history"] as Array).size(), 1,
			"active + one history entry, because that is what the data said")


func test_a_missing_policy_file_falls_back_to_documented_defaults() -> void:
	# A tunable file that will not parse may not be the reason a city cannot be
	# written. It is a reported condition, not a refusal.
	var policy := SavePolicy.load_from_files("res://data/definitely_not_here.json", true)
	assert_false(policy.is_valid())
	assert_eq(policy.max_unpinned_generations, 6, "defaults are the doc's numbers")
	assert_eq(str(policy.history_slot_min_age_s), str(SaveManager.RETENTION_SLOT_MIN_AGE_S))
	# …and the cache is untouched by the probe above.
	assert_true(SavePolicy.load_from_files().is_valid())


func test_peek_is_the_load_gate_without_the_side_effects() -> void:
	var manager := _fresh("peek")
	var section := FakeSection.new(&"economy")
	section.payload = {"treasury": 10}
	manager.register_section(section)
	assert_false(bool(manager.peek_newest()["ok"]), "nothing saved yet")
	manager.request_save("autosave", 100, 1_600_000)
	section.payload = {"treasury": 20}
	manager.request_save("autosave", 200, 1_600_300)

	var peeked := manager.peek_newest()
	assert_true(bool(peeked["ok"]))
	assert_eq(String(peeked["file"]), "gen_000002.sav")
	assert_false(bool(peeked["recovered"]))
	assert_eq(int(peeked["sim_time_minutes"]), 200)

	# Ruin the active generation and ask again: the answer moves back a
	# generation, and the ruined file is neither quarantined nor deleted.
	var path := manager.base_dir + "/gen_000002.sav"
	var file := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var text := file.get_as_text()
	file = null
	var out := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text.replace("\"treasury\":20", "\"treasury\":99"))
	out = null
	var again := manager.peek_newest()
	assert_true(bool(again["ok"]))
	assert_eq(String(again["file"]), "gen_000001.sav")
	assert_true(bool(again["recovered"]), "this would be a recovery, and it says so")
	assert_true(FileAccess.file_exists(path), "asking did not move the damaged file")
	assert_false(FileAccess.file_exists(manager.base_dir + "/quarantine/bad_gen_000002.sav"))
	assert_eq(str(manager.repair_notes), str(PackedStringArray()),
			"and it left no notes behind either")


func test_registering_a_section_twice_replaces_it() -> void:
	# The shell rebuilds its sections on every save and every load, because the
	# payload is new each time. Appending them would grow the registry without
	# bound and stringify the same key repeatedly.
	var manager := _fresh("rereg")
	manager.register_section(FakeSection.new(&"economy"))
	manager.register_section(FakeSection.new(&"economy"))
	manager.register_section(FakeSection.new(&"power"))
	assert_eq(str(manager.registered_keys()), str([&"economy", &"power"] as Array[StringName]))


func test_high_water_check() -> void:
	var manager := _fresh("highwater")
	var section := FakeSection.new(&"economy")
	manager.register_section(section)
	manager.request_save("autosave", 200, 1_600_000)
	# A candidate claiming sim time far beyond the recorded high water is rejected.
	var body := "{\"economy\":{\"section_version\":1},\"schema_version\":1,\"sim_time_minutes\":5000}"
	var digest: String = SaveManager._sha256(body)
	var verdict: Dictionary = manager._validate_candidate("gen_000001.sav", 200)
	assert_true(bool(verdict["ok"]), "sanity: real save passes at its own high water")
	var text := "{\"schema_version\":1,\"body_sha256\":\"%s\",\"body\":%s}" % [digest, body]
	var out := FileAccess.open_compressed(manager.base_dir + "/gen_000099.sav",
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out = null
	var bogus: Dictionary = manager._validate_candidate("gen_000099.sav", 200)
	assert_false(bool(bogus["ok"]))
	assert_eq(bogus["reason"], "time_ahead_of_high_water")
