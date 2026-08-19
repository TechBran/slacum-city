extends SimTest
## Doc 13 §2.2: the shell's slot layer and the Android lifecycle router.
##
## The load-bearing claim is that a slot round-trip is LOSSLESS — save, load
## into a fresh sim, and both instances must keep producing the same
## `state_hash()` when advanced (constitution §5). Everything else here is
## file-system hygiene: atomic commit, temp cleanup, listing, deletion.


## Tests never write to `user://saves` — that is a real player's profile.
const TEST_DIR := "user://test_saves/slots"


static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(path + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()


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
	# `list_slots()` must not deserialize a city. Proven by handing it a file
	# whose state is unparseable garbage: the meta still lists.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(11)
	service.save_slot(sim, 4)
	var path := service.slot_path(4)
	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file = null
	var cut := text.find("\"state\":")
	var truncated := text.substr(0, cut) + "\"state\":{ TRUNCATED"
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(truncated)
	out = null

	var slots := service.list_slots()
	assert_eq(slots.size(), 1, "header survives a corrupt body")
	assert_eq(int(slots[0]["slot"]), 4)
	assert_eq(int(slots[0]["treasury"]), sim.treasury.balance)
	# Loading it, however, must fail cleanly rather than half-restore.
	var victim := CitySim.boot_from_files(11)
	var hash_before := victim.state_hash()
	assert_false(service.load_slot(victim, 4))
	assert_eq(service.last_error, "bad_json")
	assert_eq(victim.state_hash(), hash_before, "a failed load changes nothing")
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
