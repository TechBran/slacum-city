extends SimTest
## Doc 13 §2.11 — the unclean-exit sentinel and the autosave rotation it needs.
##
## Android kills backgrounded processes with no callback of any kind, so after
## the fact a crash, an out-of-memory kill and a clean quit are the same event:
## the process is gone. The only way to tell them apart is to leave a mark
## *before*, and the value of doing so is entirely in what happens next — which
## save the shell offers.
##
## That answer is only worth having if there is more than one save to choose
## from, which is why these two features are one test file. The failure being
## defended against is not a torn file — the atomic rename already makes that
## impossible — but a **complete** file written seconds before the process died:
## structurally perfect, and holding whatever went wrong.
##
## `SaveService` used to answer that with a two-slot rotation (slot 0 and a
## shadow at slot 7). It answers it with doc 08 §2.7's generation ladder now:
## one autosave slot holding up to six digest-verified generations spread across
## 30 minutes / 6 hours / 24 hours / 7 days, walked in order by the load gate.
## Same guarantee, five deep instead of one, and with a checksum proving the
## fallback was ever whole. The sentinel's seam is unchanged — it still asks
## `last_good_autosave_slot()` and gets a slot index back.
##
## Nothing here touches a real player profile: every path is under
## `user://test_crash/`.

const RUNTIME_DIR := "user://test_crash/runtime"
const LOGS_DIR := "user://test_crash/logs"
const SAVE_DIR := "user://test_crash/slots"


## Listing first, deleting second: removing entries inside a `list_dir_begin()`
## walk skips the ones after them, and a slot that survives a wipe is a test
## running on the previous test's city.
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


func _sentinel(at_unix: float = 1_800_000_000.0) -> CrashSentinel:
	var sentinel := CrashSentinel.new()
	sentinel.runtime_dir = RUNTIME_DIR
	sentinel.logs_dir = LOGS_DIR
	sentinel.wall_clock = func() -> float: return at_unix
	return sentinel


func _fresh() -> void:
	for path: String in [RUNTIME_DIR, LOGS_DIR, SAVE_DIR]:
		DirAccess.make_dir_recursive_absolute(path)
		_wipe(path)


func _fresh_service() -> SaveService:
	var service := SaveService.new()
	service.base_dir = SAVE_DIR
	return service


# ===========================================================================
# The sentinel
# ===========================================================================

func test_a_clean_session_leaves_nothing_behind() -> void:
	_fresh()
	var first := _sentinel()
	assert_false(first.boot(), "a first launch has no flag to find")
	assert_true(first.flag_exists(), "…and leaves one while it runs")
	first.mark_clean_exit()
	assert_false(first.flag_exists())

	var second := _sentinel()
	assert_false(second.boot(), "the pause sequence cleared it: nothing to report")
	assert_eq(second.incident_path, "")
	assert_eq(second.unclean_exits, 0)


func test_a_session_that_never_paused_is_reported_on_the_next_boot() -> void:
	_fresh()
	var died := _sentinel(1_800_000_000.0)
	died.boot()
	died.note("blackout_started", "district-3")
	died.note("save", 2)
	# …and then the process is killed. No mark_clean_exit, no callbacks, nothing.

	var next := _sentinel(1_800_000_500.0)
	assert_true(next.boot(), "the flag from the dead session is still there")
	assert_eq(next.unclean_exits, 1)
	assert_ne(next.incident_path, "", "a breadcrumb file was written")
	assert_true(FileAccess.file_exists(next.incident_path))
	var payload: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(next.incident_path))
	assert_true(payload is Dictionary)
	var report: Dictionary = payload
	assert_eq(str(report["reason"]), "unclean_exit")
	assert_eq(int(report["detected_at_unix"]), 1_800_000_500)
	assert_true(str(report["app_version"]) != "", "the version is in the report")
	var previous: Dictionary = report["previous_session"]
	assert_eq(int(previous["opened_at_unix"]), 1_800_000_000,
			"…including when the session that died had started")
	# The breadcrumbs belong to the session that WROTE the file, not to the dead
	# one — the dead one's ring went with its process. Recorded so nobody reads
	# an empty list as a lost feature.
	assert_true(report["breadcrumbs"] is Array)


func test_the_incident_ring_holds_five_and_no_more() -> void:
	_fresh()
	for i in 8:
		var sentinel := _sentinel(1_800_000_000.0 + float(i))
		sentinel.boot()          # finds the previous flag: unclean, every time
	var dir := DirAccess.open(LOGS_DIR)
	var count := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("incident_"):
			count += 1
		entry = dir.get_next()
	dir.list_dir_end()
	assert_eq(count, CrashSentinel.INCIDENT_RING,
			"a crash loop must not fill the device")


func test_the_unclean_count_survives_the_process_that_saw_it() -> void:
	_fresh()
	_sentinel(1_800_000_000.0).boot()
	var second := _sentinel(1_800_000_100.0)
	second.boot()
	var third := _sentinel(1_800_000_200.0)
	third.boot()
	assert_eq(third.unclean_exits, 2, "counted across processes, not within one")


func test_breadcrumbs_are_a_bounded_ring() -> void:
	_fresh()
	var sentinel := _sentinel()
	for i in CrashSentinel.BREADCRUMB_CAPACITY + 20:
		sentinel.note("tick", i)
	var crumbs := sentinel.breadcrumbs()
	assert_eq(crumbs.size(), CrashSentinel.BREADCRUMB_CAPACITY)
	assert_eq(str(crumbs[crumbs.size() - 1]["detail"]),
			str(CrashSentinel.BREADCRUMB_CAPACITY + 19), "newest kept, oldest dropped")


# ===========================================================================
# The autosave ladder
# ===========================================================================

## Flip a byte inside a slot's active generation so the digest no longer matches
## — a save that is complete, listed, and wrong.
static func _ruin_active(service: SaveService, slot: int) -> void:
	var path := service.slot_path(slot)
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	var text := file.get_as_text()
	file = null
	var out := FileAccess.open_compressed(path, FileAccess.WRITE,
			FileAccess.COMPRESSION_ZSTD)
	out.store_string(text.replace("\"sim_time_minutes\":", "\"sim_time_minutez\":"))
	out = null


func test_the_autosave_keeps_the_generation_behind_it() -> void:
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(31)
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"one autosave slot — the depth is inside it now")
	service.autosave(sim)
	assert_eq(service.last_autosave_slot, SaveService.AUTOSAVE_SLOT)
	sim.advance_hours(1.0)
	service.autosave(sim)
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SLOT)
	var manifest := service.manager_for(SaveService.AUTOSAVE_SLOT).read_manifest()
	assert_eq(String(manifest["active"]["reason"]), "autosave")
	assert_true((manifest["history"] as Array).size() >= 1,
			"the previous city is still committed and still referenced")
	# The shadow used to have to live outside the player's visible slots. The
	# ladder lives inside slot 0, so every slot the UI shows is the player's.
	assert_true(SaveService.AUTOSAVE_SLOT
			< int(UIConfig.load_from_files().section("save_slots").get("count", 3)),
			"the autosave slot is the one the save screen labels 'Autosave'")


func test_a_ruined_newest_autosave_cannot_eat_the_city() -> void:
	# The failure this whole mechanism exists for: the newest save is complete,
	# parseable by the header reader, and wrong. One GENERATION could not
	# survive it; the ladder behind it can.
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(77)
	service.autosave(sim)                        # generation 1 — the good one
	var good_hash := sim.state_hash()
	sim.advance_hours(2.0)
	service.autosave(sim)                        # generation 2 — about to be ruined
	_ruin_active(service, SaveService.AUTOSAVE_SLOT)

	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"the health check verifies the digest, not the cheap header")
	var restored := CitySim.boot_from_files(77)
	assert_eq(service.load_latest(restored), SaveService.AUTOSAVE_SLOT,
			"a launch falls through the damaged newest generation to the one behind it")
	assert_eq(restored.state_hash(), good_hash, "…and the city is the older city")


func test_the_sentinel_points_at_the_last_good_save() -> void:
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(99)
	service.autosave(sim)
	sim.advance_hours(1.0)
	service.autosave(sim)
	var sentinel := _sentinel()
	assert_eq(sentinel.recovery_slot(service), SaveService.AUTOSAVE_SLOT,
			"the ladder loads, so the autosave slot is the right offer")

	# Nothing in the autosave slot survives: the sentinel falls back to the
	# newest save of any kind rather than to nothing.
	_wipe(service.slot_dir(SaveService.AUTOSAVE_SLOT))
	DirAccess.remove_absolute(service.slot_dir(SaveService.AUTOSAVE_SLOT))
	assert_eq(sentinel.recovery_slot(service), -1,
			"…and with no save at all, there is nothing to offer")
	service.save_slot(sim, 2)
	assert_eq(sentinel.recovery_slot(service), 2,
			"…falling back to `latest_slot()` once a manual save exists")


func test_a_health_check_is_not_a_failed_load() -> void:
	# `last_good_autosave_slot()` reads files that are expected to be damaged.
	# Reporting that through the `failed` signal would put a "save error" toast
	# in front of a player whose save is fine.
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(5)
	service.autosave(sim)
	var reported: Array[String] = []
	service.failed.connect(func(_slot: int, reason: String) -> void:
		reported.append(reason))
	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT)
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SLOT)
	assert_eq(str(reported), "[]", "a probe is not an error")
	assert_eq(service.last_error, "")


func test_recovery_is_silent_when_there_is_nothing_to_recover() -> void:
	_fresh()
	var service := _fresh_service()
	var sentinel := _sentinel()
	assert_eq(service.last_good_autosave_slot(), -1)
	assert_eq(sentinel.recovery_slot(service), -1, "a genuinely new city")
	assert_eq(sentinel.recovery_slot(null), -1)
