extends SimTest
## Doc 13 §2.2's slot API over doc 08 §2.5–§2.9's storage.
##
## The load-bearing claim is that a slot round-trip is LOSSLESS — save, load
## into a fresh sim, and both instances must keep producing the same
## `state_hash()` when advanced (constitution §5). Everything else here is
## file-system hygiene: atomic commit, temp cleanup, listing, deletion.
##
## Every behavioural assertion below predates the unification and is unchanged
## by it — the UI and the session-restore flow depend on exactly these answers.
## What did change is how a test damages a save: a slot is a generation
## directory now, so "corrupt the file" means "corrupt the generation", and the
## failure it produces is `corrupt` (a save that did not survive its digest)
## rather than `bad_json` (a file that is not a save at all).


## Tests never write to `user://saves` — that is a real player's profile.
const TEST_DIR := "user://test_saves/slots"


## Empty a directory, subdirectories and all. The listing is taken in full
## before anything is removed — deleting inside a `list_dir_begin()` walk skips
## entries, and a test that starts on somebody else's leftovers is worse than
## no test at all.
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


## Flip a byte inside the active generation's body so the SHA-256 no longer
## matches — doc 08 §2.9 check 3, reached through the shell.
static func _tamper_active_generation(service: SaveService, slot: int) -> void:
	var path := service.slot_path(slot)
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	var text := file.get_as_text()
	file = null
	text = text.replace("\"sim_time_minutes\":", "\"sim_time_minutez\":")
	var out := FileAccess.open_compressed(path, FileAccess.WRITE,
			FileAccess.COMPRESSION_ZSTD)
	out.store_string(text)
	out = null


func _fresh_service() -> SaveService:
	var service := SaveService.new()
	service.base_dir = TEST_DIR
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_wipe(TEST_DIR)
	return service


# --------------------------------------------------------------- round trip

func test_save_load_roundtrip_preserves_state_hash() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(3.0)
	var before := sim.state_hash()

	var meta := service.save_slot(sim, 1)
	assert_false(meta.is_empty(), "save_slot returned meta: " + service.last_error)
	assert_eq(int(meta["slot"]), 1)
	assert_eq(int(meta["day_index"]), sim.clock.day_index())
	assert_eq(int(meta["population"]), sim.population.city_population)
	assert_eq(int(meta["treasury"]), sim.treasury.balance)
	assert_true(int(meta["saved_at_unix"]) > 1_700_000_000, "real wall stamp")

	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, 1), "load_slot: " + service.last_error)
	assert_eq(restored.state_hash(), before, "slot restores a bit-identical city")

	# ...and the two stay identical once time moves again: the floats came back
	# as floats, not as decimal approximations.
	sim.advance_hours(6.0)
	restored.advance_hours(6.0)
	assert_eq(restored.state_hash(), sim.state_hash(),
			"restored city stays deterministic after the load")
	service.free()


func test_placed_building_survives_a_slot() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(99)
	var origin := Vector2i(-1, -1)
	for z in range(32, 80):
		for x in range(32, 80):
			var candidate := Vector2i(x, z)
			if sim.world.grid.can_place(candidate, Vector2i.ONE) \
					and sim.grid.would_serve(candidate):
				origin = candidate
				break
		if origin.x >= 0:
			break
	assert_true(origin.x >= 0, "core has a serviceable vacant lot")
	assert_true(bool(sim.cmd_place_building("store", origin)["ok"]))
	sim.advance_hours(2.0)
	assert_false(service.save_slot(sim, 2).is_empty())

	var restored := CitySim.boot_from_files(99)
	assert_true(service.load_slot(restored, 2))
	assert_eq(restored.buildings.size(), sim.buildings.size())
	assert_eq(restored.state_hash(), sim.state_hash())
	service.free()


# ------------------------------------------------------------------- listing

func test_list_and_delete_slots() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(7)
	assert_eq(service.list_slots().size(), 0, "no slots on a clean profile")

	service.save_slot(sim, 3)
	sim.advance_hours(1.0)
	service.save_slot(sim, 1)
	var slots := service.list_slots()
	assert_eq(slots.size(), 2)
	assert_eq(int(slots[0]["slot"]), 1, "ascending by slot index")
	assert_eq(int(slots[1]["slot"]), 3)
	for meta in slots:
		assert_true(meta.has_all(["slot", "saved_at_unix", "day_index",
				"population", "treasury"]), "meta carries the documented keys")
	assert_eq(int(slots[0]["treasury"]), sim.treasury.balance)

	assert_true(service.delete_slot(3))
	assert_eq(service.list_slots().size(), 1)
	assert_false(service.has_slot(3))
	assert_true(service.delete_slot(3), "deleting an empty slot is a no-op success")
	service.free()


func test_list_slots_reads_only_the_header() -> void:
	# `list_slots()` must not deserialize a city. Proven by ruining the body and
	# listing anyway: the header lives in `manifest.json`, which the ruined
	# generation cannot take with it.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(11)
	service.save_slot(sim, 4)
	_tamper_active_generation(service, 4)

	var slots := service.list_slots()
	assert_eq(slots.size(), 1, "header survives a corrupt body")
	assert_eq(int(slots[0]["slot"]), 4)
	assert_eq(int(slots[0]["treasury"]), sim.treasury.balance)
	# Loading it, however, must fail cleanly rather than half-restore.
	var victim := CitySim.boot_from_files(11)
	var hash_before := victim.state_hash()
	assert_false(service.load_slot(victim, 4))
	assert_eq(service.last_error, "corrupt",
			"the digest caught it — this is a save that did not survive, not a stray file")
	assert_eq(victim.state_hash(), hash_before, "a failed load changes nothing")
	assert_true(FileAccess.file_exists(
			service.slot_dir(4) + "/quarantine/bad_gen_000001.sav"),
			"doc 08 §2.9: quarantined, never deleted, so a support path exists")
	service.free()


func test_delete_takes_the_quarantine_with_it() -> void:
	# `delete_slot` removes a tree, and a slot that has quarantined anything has
	# a subdirectory in it. A partial removal is the worst failure this method
	# has: "delete this city" would leave a city behind for the next launch to
	# resume.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(909)
	service.save_slot(sim, 1)
	_tamper_active_generation(service, 1)
	assert_false(service.load_slot(CitySim.boot_from_files(909), 1))
	assert_true(FileAccess.file_exists(
			service.slot_dir(1) + "/quarantine/bad_gen_000001.sav"),
			"there is now a subdirectory with a file in it")

	assert_true(service.delete_slot(1))
	assert_false(DirAccess.dir_exists_absolute(service.slot_dir(1)),
			"the whole tree went, quarantine included")
	assert_eq(service.list_slots().size(), 0)
	service.free()


func test_the_header_is_a_cache_and_the_body_is_the_record() -> void:
	# `manifest.active.meta` is where a load screen reads the header from, but it
	# is a CACHE of the `meta` save section, not the only copy. Strip it from the
	# manifest — a hand-edit, or a manifest from a build that predates the
	# convention — and the slot must still list, by paying for the decompress.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(808)
	sim.advance_hours(2.0)
	service.save_slot(sim, 5)
	var path := service.slot_dir(5) + "/manifest.json"
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	(manifest["active"] as Dictionary).erase("meta")
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(manifest, "", true))
	out = null

	var slots := service.list_slots()
	assert_eq(slots.size(), 1, "the slot did not vanish with its cache")
	assert_eq(int(slots[0]["slot"]), 5)
	assert_eq(int(slots[0]["treasury"]), sim.treasury.balance,
			"…and the header came back off the `meta` section in the body")
	assert_eq(int(slots[0]["day_index"]), sim.clock.day_index())
	assert_eq(int(slots[0]["saved_at_unix"]),
			int((manifest["active"] as Dictionary)["real_unix"]),
			"with the stamp taken from the manifest entry it was cached beside")
	service.free()


func test_a_torn_file_is_still_reported_as_unparseable() -> void:
	# The other half of the failure taxonomy: `bad_json` is what the shell says
	# when the bytes are not a save envelope at all, and the UI copy for the two
	# cases is different.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(11)
	service.save_slot(sim, 4)
	var out := FileAccess.open_compressed(service.slot_path(4),
			FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	out.store_string("{\"schema_version\":1,\"body_sha256\":")   # torn
	out = null
	assert_false(service.load_slot(CitySim.boot_from_files(11), 4))
	assert_eq(service.last_error, "bad_json")
	service.free()


# ------------------------------------------------------------------ hygiene

func test_write_is_atomic_and_leaves_no_temp() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(5)
	service.save_slot(sim, 0)
	assert_false(FileAccess.file_exists(service.slot_path(0) + SaveService.TEMP_SUFFIX),
			"temp file renamed away, never left behind")
	# Overwriting an occupied slot also commits by rename.
	sim.advance_hours(4.0)
	var meta := service.save_slot(sim, 0)
	assert_false(meta.is_empty())
	assert_false(FileAccess.file_exists(service.slot_path(0) + SaveService.TEMP_SUFFIX))
	var reloaded := CitySim.boot_from_files(5)
	assert_true(service.load_slot(reloaded, 0))
	assert_eq(reloaded.state_hash(), sim.state_hash(), "second write won")
	service.free()


func test_orphan_temp_is_cleared_by_delete() -> void:
	# A process killed mid-write leaves `slot_N.json.tmp`. It must never be
	# mistaken for a save, and delete must sweep it.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(5)
	service.save_slot(sim, 2)
	var orphan := service.slot_path(2) + SaveService.TEMP_SUFFIX
	var file := FileAccess.open(orphan, FileAccess.WRITE)
	file.store_string("{\"format\":1,\"meta\":{\"slot\":2},\"state\":")  # torn
	file = null
	assert_eq(service.list_slots().size(), 1, "a .tmp is not a slot")
	assert_true(service.delete_slot(2))
	assert_false(FileAccess.file_exists(orphan), "orphan temp swept")
	service.free()


func test_bad_slots_and_missing_files_fail_cleanly() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(5)
	assert_true(service.save_slot(sim, -1).is_empty())
	assert_eq(service.last_error, "invalid_slot")
	assert_true(service.save_slot(sim, SaveService.MAX_SLOTS).is_empty())
	assert_eq(service.last_error, "invalid_slot")
	assert_false(service.load_slot(sim, 6))
	assert_eq(service.last_error, "missing")
	assert_false(service.delete_slot(-1))
	assert_true(service.save_slot(null, 1).is_empty())
	assert_eq(service.last_error, "no_state")
	service.free()


func test_autosave_targets_the_reserved_slot() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(21)
	sim.advance_hours(2.0)
	service.autosave(sim)
	assert_eq(service.last_error, "")
	assert_true(service.has_slot(SaveService.AUTOSAVE_SLOT))
	assert_true(service.last_autosave_unix > 0)
	var slots := service.list_slots()
	assert_eq(slots.size(), 1)
	assert_eq(int(slots[0]["slot"]), SaveService.AUTOSAVE_SLOT)
	service.free()


# ----------------------------------------------------------------- lifecycle

class ClockRig extends RefCounted:
	var wall: float = 1_800_000_000.0
	var mono: float = 100.0

	func wall_now() -> float:
		return wall

	func mono_now() -> float:
		return mono


func _rigged_lifecycle(service: SaveService, sim: Object, rig: ClockRig) -> AndroidLifecycle:
	var lifecycle := AndroidLifecycle.new()
	lifecycle.setup(service, sim)
	lifecycle.wall_clock = rig.wall_now
	lifecycle.mono_clock = rig.mono_now
	return lifecycle


func test_pause_autosaves_and_resume_reports_elapsed() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(33)
	var rig := ClockRig.new()
	var lifecycle := _rigged_lifecycle(service, sim, rig)

	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_true(service.has_slot(SaveService.AUTOSAVE_SLOT),
			"the pause sequence commits the city before the process is at risk")

	# Away for 90 real minutes; the device slept, so the monotonic clock only
	# advanced a little. Wall time is the truth here.
	rig.wall += 5400.0
	rig.mono += 12.0
	var seen: Array[float] = []
	lifecycle.resumed.connect(func(elapsed: float) -> void: seen.append(elapsed))
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(seen.size(), 1)
	assert_almost_eq(seen[0], 5400.0, 0.001)
	assert_almost_eq(lifecycle.last_elapsed_wall_s, 5400.0, 0.001)
	assert_eq(lifecycle.last_anomaly, "")
	# The 12 h cap is CitySim's (C-19); this node reports raw elapsed time.
	lifecycle.free()
	service.free()


func test_resume_without_a_pause_reports_zero() -> void:
	var service := _fresh_service()
	var rig := ClockRig.new()
	var lifecycle := _rigged_lifecycle(service, CitySim.boot_from_files(1), rig)
	var seen: Array[float] = []
	lifecycle.resumed.connect(func(elapsed: float) -> void: seen.append(elapsed))
	rig.wall += 999.0
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(seen, [0.0] as Array[float])
	lifecycle.free()
	service.free()


func test_clock_moved_backwards_falls_back_to_monotonic() -> void:
	var service := _fresh_service()
	var rig := ClockRig.new()
	var lifecycle := _rigged_lifecycle(service, CitySim.boot_from_files(1), rig)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	# User (or NTP) moved the device clock back an hour while 600 s really passed.
	rig.wall -= 3600.0
	rig.mono += 600.0
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	assert_almost_eq(lifecycle.last_elapsed_wall_s, 600.0, 0.001,
			"monotonic is a hard lower bound on elapsed real time")
	assert_eq(lifecycle.last_anomaly, "clock_backwards")
	lifecycle.free()
	service.free()


func test_back_press_autosaves_but_is_rate_limited() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(8)
	var rig := ClockRig.new()
	var lifecycle := _rigged_lifecycle(service, sim, rig)
	# GDScript lambdas capture locals by value, so the counters live in arrays.
	var backs: Array[int] = [0]
	var writes: Array[int] = [0]
	lifecycle.back_requested.connect(func() -> void: backs[0] += 1)
	service.saved.connect(func(_meta: Dictionary) -> void: writes[0] += 1)

	lifecycle.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	assert_eq(backs[0], 1)
	assert_eq(writes[0], 1, "back commits the city")
	assert_true(service.has_slot(SaveService.AUTOSAVE_SLOT))

	# A second back a moment later closes a panel — it must not re-write.
	rig.wall += 1.0
	rig.mono += 1.0
	lifecycle.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	assert_eq(backs[0], 2, "the signal still fires, so the UI still routes it")
	assert_eq(writes[0], 1, "rate-limited")

	# Past the interval it writes again.
	rig.mono += AndroidLifecycle.BACK_AUTOSAVE_MIN_INTERVAL_S
	lifecycle.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	assert_eq(writes[0], 2)
	lifecycle.free()
	service.free()


func test_lifecycle_without_wiring_is_harmless() -> void:
	# main.gd may create the node before the sim exists; notifications must not
	# crash and must report the save as refused.
	var lifecycle := AndroidLifecycle.new()
	var results: Array[bool] = []
	lifecycle.paused.connect(func(saved: bool) -> void: results.append(saved))
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	assert_eq(results, [false] as Array[bool])
	lifecycle.notification(Node.NOTIFICATION_OS_MEMORY_WARNING)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	lifecycle.free()


# ------------------------------------------------- session restore (doc 08)

func test_latest_slot_and_load_latest_resume_the_newest_save() -> void:
	# The boot path resumes from the NEWEST save, manual or autosave — this is
	# the fix for the launch-day defect where saves wrote but nothing ever
	# read them back and every launch was a fresh founding.
	var service := _fresh_service()
	assert_eq(service.latest_slot(), -1, "no saves -> no latest")
	var throwaway := CitySim.boot_from_files(1)
	assert_eq(service.load_latest(throwaway), -1, "nothing to resume is not an error")
	var sim := CitySim.boot_from_files(777)
	sim.cmd_place_building("house", Vector2i(35, 33))
	sim.advance_hours(2.0)
	service.save_slot(sim, 3)                       # older manual save
	sim.advance_hours(1.0)
	# `saved_at_unix` has 1 s resolution; stamp the autosave newer explicitly.
	service.autosave(sim)                           # newest: the autosave
	var meta := service._slot_meta(0)
	assert_true(int(meta["saved_at_unix"]) >= int(service._slot_meta(3)["saved_at_unix"]))
	var restored := CitySim.boot_from_files(777)
	var slot := service.load_latest(restored)
	assert_eq(slot, 0, "the autosave was newest")
	sim.advance_hours(4.0)
	restored.advance_hours(4.0)
	assert_eq(restored.state_hash(), sim.state_hash(),
			"the resumed city IS the saved city, buildings and all")
	assert_eq(restored.buildings.size(), 35, "the placed house survived the relaunch")


func test_ui_section_rides_the_envelope() -> void:
	# Doc 12 §3.2: tutorial progress and overlay prefs travel with the save,
	# so a finished tutorial never restarts on a resumed city.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(1.0)
	service.ui_provider = func() -> Dictionary:
		return {"section_version": 1, "onboarding": {"finished": true, "skipped": false}}
	service.save_slot(sim, 1)
	service.last_loaded_ui = {"poisoned": true}     # must be overwritten by load
	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, 1))
	assert_eq(bool((service.last_loaded_ui.get("onboarding", {}) as Dictionary)
			.get("finished", false)), true, "the ui section came back with the load")
	# A service with no provider writes an empty section and loads it as {}.
	var bare := _fresh_service()
	bare.save_slot(sim, 2)
	assert_true(bare.load_slot(restored, 2))
	assert_eq(bare.last_loaded_ui, {}, "no provider -> empty ui section, never an error")


# =========================================================== doc 08 underneath
# The unification's whole point: the generation ladder, the digest gate, the
# retention policy and the section ladders are now on the path the app runs,
# not beside it. Each test below is a doc 08 §2.x row that doc 91 §8 marked
# PARTIAL for one reason — it was written, tested, and unreachable.

func test_a_slot_is_a_generation_ladder() -> void:
	# Doc 08 §2.5/§2.6: the manifest rename is the commit point, and the
	# previous generation is still on disk and still referenced.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(202)
	service.save_slot(sim, 1)
	sim.advance_hours(1.0)
	service.save_slot(sim, 1)
	var manifest := service.manager_for(1).read_manifest()
	assert_eq(String(manifest["active"]["file"]), "gen_000002.sav")
	assert_eq(int(manifest["manifest_version"]), SaveManager.MANIFEST_VERSION)
	assert_eq((manifest["history"] as Array).size(), 1, "generation 1 retained")
	assert_true(FileAccess.file_exists(service.slot_dir(1) + "/gen_000001.sav"))
	assert_eq(String(manifest["active"]["reason"]), "manual")
	assert_true(int(manifest["active"]["bytes"]) > 0)
	assert_eq(int(manifest["high_water_sim_minutes"]), sim.clock.sim_time_minutes())
	service.free()


func test_a_ruined_generation_falls_through_to_the_one_behind_it() -> void:
	# This is the failure the two-slot autosave shadow existed for, answered by
	# doc 08 §2.7's ladder instead: the newest save is complete, listed, and
	# wrong, and the city that comes back is the one before it.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(303)
	service.autosave(sim)
	var good_hash := sim.state_hash()
	sim.advance_hours(2.0)
	service.autosave(sim)
	_tamper_active_generation(service, SaveService.AUTOSAVE_SLOT)

	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"the probe walks the ladder, so the slot still answers")
	var restored := CitySim.boot_from_files(303)
	assert_true(service.load_slot(restored, SaveService.AUTOSAVE_SLOT))
	assert_eq(restored.state_hash(), good_hash, "…and the city is the older city")
	assert_true(service.last_load_recovered, "doc 08 §2.9: this was a recovery")
	assert_true(service.last_load_lost_minutes > 0,
			"and it says how much play it cost (%d min)" % service.last_load_lost_minutes)
	service.free()


func test_the_probe_never_damages_what_it_inspects() -> void:
	# `last_good_autosave_slot()` reads files that are EXPECTED to be damaged.
	# Quarantining one as a side effect of asking would turn a health check into
	# a destructive act.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(404)
	service.autosave(sim)
	sim.advance_hours(1.0)
	service.autosave(sim)
	_tamper_active_generation(service, SaveService.AUTOSAVE_SLOT)
	var reported: Array[String] = []
	service.failed.connect(func(_slot: int, reason: String) -> void:
		reported.append(reason))

	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT)
	assert_eq(str(reported), "[]", "a health check is not a failed load")
	assert_eq(service.last_error, "")
	assert_true(FileAccess.file_exists(service.slot_dir(0) + "/gen_000002.sav"),
			"the damaged generation is still exactly where it was")
	assert_false(FileAccess.file_exists(
			service.slot_dir(0) + "/quarantine/bad_gen_000002.sav"),
			"nothing quarantined by a question")
	service.free()


func test_retention_comes_from_data_and_bounds_the_slot() -> void:
	# Doc 08 §2.7 / §8: at most `max_unpinned_generations` on disk, and the
	# count is a tunable rather than a constant inside the writer.
	var service := _fresh_service()
	assert_eq(service.policy.max_unpinned_generations, 6,
			"data/persistence.json's documented count")
	assert_eq(service.policy.history_slot_min_age_s.size(),
			service.policy.max_unpinned_generations - 1,
			"the ladder is exactly as deep as the count allows (A is the active)")
	var sim := CitySim.boot_from_files(505)
	for i in 9:
		service.save_slot(sim, 2)
	var generations := 0
	var dir := DirAccess.open(service.slot_dir(2))
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("gen_"):
			generations += 1
		entry = dir.get_next()
	dir.list_dir_end()
	assert_true(generations <= service.policy.max_unpinned_generations,
			"nine saves, %d generations kept" % generations)
	assert_true(service.load_slot(CitySim.boot_from_files(505), 2),
			"and the slot still loads afterwards")
	service.free()


func test_a_pinned_checkpoint_is_never_swept() -> void:
	# Doc 08 §2.7: `pre_migration` and `pre_catchup` are pinned, which is what
	# makes a migration or a catch-up commit reversible.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(606)
	service.save_slot(sim, 1, "pre_catchup")
	for i in 8:
		sim.advance_hours(1.0)
		service.save_slot(sim, 1, "autosave")
	var manifest := service.manager_for(1).read_manifest()
	assert_eq(String((manifest["pinned"] as Dictionary)["pre_catchup"]), "gen_000001.sav")
	assert_true(FileAccess.file_exists(service.slot_dir(1) + "/gen_000001.sav"),
			"eight autosaves later the pin is still on disk")
	service.free()


func test_the_sim_body_is_a_versioned_section_with_a_ladder() -> void:
	# Doc 08 §2.8: `section_version` inside every section, with its own ladder.
	# `sim/city_sim.gd` now answers both hooks itself, so this test asserts the
	# SHELL's half — that whatever rung the sim writes, a reader one rung further
	# on is handed the body through `migrate_section` rather than around it.
	# Written relative to `CitySim.SAVE_SECTION_VERSION` rather than against the
	# literals 1 and 2 so the next epoch bump does not break a test about the
	# plumbing (it broke this one once, which is why it reads this way).
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(707)
	service.save_slot(sim, 1)
	var probe := VersionedSim.new()
	probe.version = CitySim.SAVE_SECTION_VERSION + 1
	assert_true(service.load_slot(probe, 1), "a body one rung down loads into a newer reader")
	assert_eq(probe.migrated_from, CitySim.SAVE_SECTION_VERSION,
			"…through the section ladder, not around it")
	assert_true(bool(probe.restored.get("_migrated", false)))
	assert_true(probe.restored.has("clock"), "and the body itself arrived intact")
	service.free()


## A stand-in for the sim's half of the section contract: it answers
## `canonical_capture` / `restore_state` the way `CitySim` does and adds the two
## ladder methods `SaveService` duck-types for.
class VersionedSim extends RefCounted:
	var version: int = 1
	var restored: Dictionary = {}
	var migrated_from: int = -1

	func canonical_capture() -> Dictionary:
		return {"clock": {"tick": 4}}

	func restore_state(body: Dictionary) -> void:
		restored = body

	func save_section_version() -> int:
		return version

	func migrate_save_section(data: Dictionary, from_version: int) -> Dictionary:
		migrated_from = from_version
		data["_migrated"] = true
		return data


# ═══════════ ASYNC WRITES (doc 13 §2.2, report 98 RR-40) ═══════════════════
#
# The write half may leave the main thread; the CAPTURE half may not, and the
# PAUSE path may not leave it either — doc 13 §2.2 gives the process no promise
# that it survives the callback, and a dispatched write is not a committed one.
# Everything below is one of those three claims, or the recovery contract that
# has to keep holding while a write is in flight.
#
# These tests never enter a SceneTree, so `_process` never runs and
# `flush_writes()` is the only settle path — which is deliberate: it is the same
# path the pause sequence and every slot reader take, so exercising it here
# exercises the one that matters.

func _async_service() -> SaveService:
	var service := _fresh_service()
	service.async_writes = true
	return service


func test_an_async_save_round_trips_bit_identically() -> void:
	var service := _async_service()
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(3.0)
	var before := sim.state_hash()
	var announced: Array = []
	service.saved.connect(func(m: Dictionary) -> void: announced.append(m))

	var meta := service.save_slot(sim, 1)
	assert_false(meta.is_empty(), "the header comes back at once: " + service.last_error)
	assert_eq(announced.size(), 0, "…and `saved` has NOT fired yet")

	service.flush_writes()
	assert_false(service.write_pending(), "the queue is empty after a flush")
	assert_eq(announced.size(), 1, "`saved` fires exactly once, on the main thread")

	var restored := CitySim.boot_from_files(4242)
	assert_true(service.load_slot(restored, 1), "load_slot: " + service.last_error)
	assert_eq(restored.state_hash(), before, "a threaded write is a lossless one")
	service.free()


func test_the_pause_path_commits_before_it_returns() -> void:
	# Doc 13 §2.2 step 2: Android may kill the process the moment the pause
	# callback returns, so `pause` is in SYNC_REASONS and stays there. This test
	# is the guard on that list — a reason quietly moved out of it would show up
	# nowhere else until a player lost a city.
	var service := _async_service()
	var sim := CitySim.boot_from_files(99)
	sim.advance_hours(1.0)
	# A slot each, so the assertion is "this reason committed" and not "some
	# earlier reason left a manifest lying about".
	for i in SaveService.SYNC_REASONS.size():
		var reason := String(SaveService.SYNC_REASONS[i])
		var slot := 1 + i
		var meta := service.save_slot(sim, slot, reason)
		assert_false(meta.is_empty(), "%s saved: %s" % [reason, service.last_error])
		assert_false(service.write_pending(),
				"`%s` left nothing queued" % reason)
		assert_true(FileAccess.file_exists(service.slot_dir(slot) + "/manifest.json"),
				"`%s` committed the manifest before returning" % reason)
	assert_eq(service.last_error, "", "and none of them failed")
	service.free()


func test_back_to_back_async_saves_serialise() -> void:
	# The concurrent-save stress. `commit_save` reads the generation number out
	# of the manifest, so two commits in flight at once would race for it; the
	# contract is that a second request settles the first. Six saves with no
	# flush between them must therefore produce six generations in order, and the
	# newest must load.
	var service := _async_service()
	var sim := CitySim.boot_from_files(77)
	# An Array, not an int: a GDScript lambda captures a local by VALUE, so a
	# counter incremented inside one never reaches the enclosing scope.
	var announced: Array = []
	service.saved.connect(func(_m: Dictionary) -> void: announced.append(1))
	var stamps: Array[int] = []
	for i in 6:
		sim.advance_hours(0.5)
		var meta := service.save_slot(sim, 3, "manual")
		assert_false(meta.is_empty(), "save %d: %s" % [i, service.last_error])
		stamps.append(int(meta["sim_time_minutes"]))
		assert_true(service.write_pending() or i == 0,
				"save %d is queued rather than blocking" % i)
	service.flush_writes()
	assert_eq(announced.size(), 6,
			"six writes, six signals, none lost and none doubled")

	var manifest := service.manager_for(3).read_manifest()
	assert_eq(int(manifest["next_generation"]), 7, "six generations were numbered 1..6")
	assert_eq(int(manifest["active"]["sim_time_minutes"]), stamps[5],
			"the ACTIVE generation is the last city that was captured")
	var restored := CitySim.boot_from_files(77)
	assert_true(service.load_slot(restored, 3), "…and it loads: " + service.last_error)
	assert_eq(restored.state_hash(), sim.state_hash(), "as the city that was saved")
	service.free()


func test_every_slot_reader_settles_the_queue_first() -> void:
	# Nothing in the codebase may observe a half-written ladder, so each reader
	# flushes on the way in. Without that, `list_slots()` a frame after an
	# autosave would report the generation BEFORE it.
	var service := _async_service()
	var sim := CitySim.boot_from_files(5150)
	sim.advance_hours(2.0)
	service.save_slot(sim, 4, "manual")
	assert_true(service.write_pending(), "the write is queued")
	var listed := service.list_slots()
	assert_false(service.write_pending(), "list_slots() settled it")
	var found := false
	for meta: Dictionary in listed:
		if int(meta.get("slot", -1)) == 4:
			found = true
			assert_eq(int(meta["sim_time_minutes"]), sim.clock.sim_time_minutes(),
					"and reported the city that was just captured")
	assert_true(found, "the freshly written slot is in the listing")

	service.save_slot(sim, 4, "manual")
	assert_true(service.has_slot(4), "has_slot() settles it too")
	assert_false(service.write_pending(), "…and leaves nothing behind")
	service.free()


func test_a_kill_before_the_rename_leaves_the_previous_city_active() -> void:
	# The write is `.tmp` then rename, and the manifest rename is the commit
	# point (doc 08 §2.5). A process killed between the two therefore leaves an
	# orphan and the PREVIOUS generation still active — which must still load,
	# and the orphan must be swept rather than accumulate.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(31337)
	sim.advance_hours(2.0)
	service.save_slot(sim, 5, "manual")
	var good := sim.state_hash()

	# The kill: a half-written generation file with no manifest entry.
	var orphan := service.slot_dir(5) + "/gen_000009.sav.tmp"
	var half := FileAccess.open(orphan, FileAccess.WRITE)
	half.store_string("{\"schema_version\":1,\"body_sha")
	half = null
	assert_true(FileAccess.file_exists(orphan), "the torn write is on disk")

	var restored := CitySim.boot_from_files(31337)
	assert_true(service.load_slot(restored, 5),
			"the committed city still loads: " + service.last_error)
	assert_eq(restored.state_hash(), good, "…unchanged by the torn write beside it")
	assert_false(service.last_load_recovered,
			"and it is the ACTIVE generation, not a recovery")
	service.free()


func test_a_torn_active_generation_is_quarantined_and_the_ladder_recovers() -> void:
	# The other kill: the generation renamed, the manifest committed, and the
	# bytes are wrong anyway (a flash that lied about its flush). Doc 08 §2.9's
	# gate must refuse it, MOVE it to quarantine so the next boot does not pay
	# for it again, and hand back the generation behind it.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(2718)
	sim.advance_hours(1.5)
	service.save_slot(sim, 6, "manual")
	var first := sim.state_hash()
	var first_minutes := sim.clock.sim_time_minutes()
	sim.advance_hours(1.5)
	service.save_slot(sim, 6, "manual")
	var torn_file := service.slot_path(6).get_file()
	_tamper_active_generation(service, 6)

	var restored := CitySim.boot_from_files(2718)
	assert_true(service.load_slot(restored, 6),
			"the ladder recovers: " + service.last_error)
	assert_true(service.last_load_recovered, "…and says so")
	assert_eq(restored.state_hash(), first, "the generation behind it is the city")
	assert_true(service.last_load_lost_minutes > 0,
			"and the player is told how much time it cost (%d minutes)"
			% service.last_load_lost_minutes)
	assert_eq(restored.clock.sim_time_minutes(), first_minutes,
			"which is the difference between the two captures")
	assert_true(FileAccess.file_exists(
			service.slot_dir(6) + "/quarantine/bad_" + torn_file),
			"the torn generation was moved to quarantine, not left in the walk")
	service.free()


func test_a_queued_write_survives_the_service_leaving_the_tree() -> void:
	# A process that ends with a write still queued is a lost save. `free()`
	# runs NOTIFICATION_PREDELETE, which flushes — so even a shell that forgets
	# cannot drop one.
	var service := _async_service()
	var sim := CitySim.boot_from_files(8080)
	sim.advance_hours(1.0)
	var meta := service.save_slot(sim, 7, "manual")
	assert_false(meta.is_empty(), "queued: " + service.last_error)
	assert_true(service.write_pending(), "…and still in flight")
	service.free()

	var reader := _reopen_service()
	var restored := CitySim.boot_from_files(8080)
	assert_true(reader.load_slot(restored, 7),
			"the queued write landed anyway: " + reader.last_error)
	assert_eq(restored.state_hash(), sim.state_hash(), "whole and correct")
	reader.free()


## A second service over the SAME directory, without the wipe `_fresh_service`
## does — for reading back what another instance wrote.
func _reopen_service() -> SaveService:
	var service := SaveService.new()
	service.base_dir = TEST_DIR
	return service
