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
## from, which is why these two features are one test file. `SaveService`
## alternates its autosave between slot 0 and slot 7, so the newest is never the
## only copy: the failure the rotation defends against is not a torn file (the
## atomic rename already makes that impossible) but a **complete** file written
## seconds before the process died — structurally perfect, and holding whatever
## went wrong.
##
## Nothing here touches a real player profile: every path is under
## `user://test_crash/`.

const RUNTIME_DIR := "user://test_crash/runtime"
const LOGS_DIR := "user://test_crash/logs"
const SAVE_DIR := "user://test_crash/slots"


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
# The autosave rotation
# ===========================================================================

func test_the_autosave_alternates_between_two_slots() -> void:
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(31)
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"the first autosave lands on the primary slot")
	service.autosave(sim)
	assert_eq(service.last_autosave_slot, SaveService.AUTOSAVE_SLOT)
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SHADOW_SLOT,
			"the second lands on the shadow, because it is the older of the two")
	service.autosave(sim)
	assert_eq(service.last_autosave_slot, SaveService.AUTOSAVE_SHADOW_SLOT)
	assert_true(service.has_slot(SaveService.AUTOSAVE_SLOT))
	assert_true(service.has_slot(SaveService.AUTOSAVE_SHADOW_SLOT))
	assert_true(SaveService.AUTOSAVE_SHADOW_SLOT
			>= UIConfig.load_from_files().section("save_slots").get("count", 3),
			"the shadow sits outside every slot the player can see")


func test_a_ruined_newest_autosave_cannot_eat_the_city() -> void:
	# The failure this whole rotation exists for: the newest save is complete,
	# parseable by the header reader, and wrong. One slot could not survive it.
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(77)
	service.autosave(sim)                        # slot 0 — the good one
	var good_hash := sim.state_hash()
	sim.advance_hours(2.0)
	service.autosave(sim)                        # slot 7 — about to be ruined
	var victim := service.slot_path(SaveService.AUTOSAVE_SHADOW_SLOT)
	var file := FileAccess.open(victim, FileAccess.WRITE)
	file.store_string("{\"format\":1,\"meta\":{\"slot\":7,\"saved_at_unix\":9999999999},\"ui\":{},\"state\":")
	file = null                                   # truncated mid-write

	assert_eq(service.last_good_autosave_slot(), SaveService.AUTOSAVE_SLOT,
			"the health check reads the whole file, not the cheap header")
	var restored := CitySim.boot_from_files(77)
	assert_eq(service.load_latest(restored), SaveService.AUTOSAVE_SLOT,
			"a launch falls through the damaged newest save to the one behind it")
	assert_eq(restored.state_hash(), good_hash, "…and the city is the older city")


func test_the_sentinel_points_at_the_last_good_save() -> void:
	_fresh()
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(99)
	service.autosave(sim)
	sim.advance_hours(1.0)
	service.autosave(sim)
	var sentinel := _sentinel()
	assert_eq(sentinel.recovery_slot(service), SaveService.AUTOSAVE_SHADOW_SLOT,
			"both halves load, so the newest is the right offer")

	var file := FileAccess.open(service.slot_path(SaveService.AUTOSAVE_SHADOW_SLOT),
			FileAccess.WRITE)
	file.store_string("not json at all")
	file = null
	assert_eq(sentinel.recovery_slot(service), SaveService.AUTOSAVE_SLOT,
			"…and when it does not, the other half is")


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
	assert_eq(service.next_autosave_slot(), SaveService.AUTOSAVE_SHADOW_SLOT)
	assert_eq(str(reported), "[]", "the missing shadow slot is not an error")
	assert_eq(service.last_error, "")


func test_recovery_is_silent_when_there_is_nothing_to_recover() -> void:
	_fresh()
	var service := _fresh_service()
	var sentinel := _sentinel()
	assert_eq(service.last_good_autosave_slot(), -1)
	assert_eq(sentinel.recovery_slot(service), -1, "a genuinely new city")
	assert_eq(sentinel.recovery_slot(null), -1)
