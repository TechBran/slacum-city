extends SimTest
## THE COLD LAUNCH (report 98 §48, RR-132 / RR-134) — doc 08's Core Rule 2 on
## the path Android actually uses.
##
## **The defect this file exists for.** The only `CatchUpPlanner` call in the
## game sat inside `Main._on_app_resumed`, reachable only from
## `AndroidLifecycle.resumed`, which fires only for
## `NOTIFICATION_APPLICATION_RESUMED` — a notification a *dead process* never
## gets. `_paused_wall` was an in-memory member, `-1.0` at every boot and never
## seeded from disk, and `manifest.active.real_unix` was written by two files and
## read by none. So after a process death, a swipe-away, a low-memory kill or the
## title door's CONTINUE, the city resumed **frozen at the pause**: Core Rule 2
## was void on the commonest way back into an Android game.
##
## The claim pinned below is the strong form: **a city saved, cold-loaded and
## advanced by the stamped absence is BIT-IDENTICAL to the same city taken
## through the in-process resume path over the same absence.** One code path owns
## catch-up; the cold launch is a different way of measuring the elapsed time and
## nothing else.
##
## `ShellResumeRig` mirrors `game/main.gd`'s snippets — see its class doc.

const TEST_DIR := "user://test_cold_launch/slots"
const T0 := 1_800_000_000.0
const SLOT := 1


class ClockRig extends RefCounted:
	var wall: float = T0
	var mono: float = 100.0

	func wall_now() -> float:
		return wall

	func mono_now() -> float:
		return mono


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
	service.base_dir = TEST_DIR
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_wipe(TEST_DIR)
	return service


func _lifecycle(service: SaveService, sim: CitySim, rig: ClockRig) -> AndroidLifecycle:
	var lifecycle := AndroidLifecycle.new()
	lifecycle.setup(service, sim)
	lifecycle.wall_clock = rig.wall_now
	lifecycle.mono_clock = rig.mono_now
	return lifecycle


## A city, paused (which commits it with doc 13 §3.2's stamp), and the shell rig
## that owns it. Returns `{sim, service, lifecycle, rig, shell}`.
func _paused_city(seed_value: int, warm_hours: float = 2.0) -> Dictionary:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(seed_value)
	sim.advance_hours(warm_hours)
	var rig := ClockRig.new()
	var lifecycle := _lifecycle(service, sim, rig)
	var shell := ShellResumeRig.new()
	shell.setup(sim, service, lifecycle)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	return {"sim": sim, "service": service, "lifecycle": lifecycle,
			"rig": rig, "shell": shell}


# ===========================================================================
# The stamp reaches disk
# ===========================================================================

func test_the_pause_save_carries_doc_13_s_last_pause_stamp() -> void:
	var world := _paused_city(11)
	var service: SaveService = world["service"]
	assert_eq(service.last_error, "", "the pause save committed")
	# A fresh service, a fresh sim: nothing in memory survives this.
	var reader := SaveService.new()
	reader.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(11)
	assert_true(reader.load_slot(cold, SaveService.AUTOSAVE_SLOT), reader.last_error)
	var stamp := LifecycleStamp.read(reader.last_loaded_android)
	assert_false(stamp.is_empty(),
			"the generation on disk carries save.android.last_pause")
	assert_eq(int(stamp["unix_s"]), int(T0))
	assert_true(bool(stamp["clean"]), "a lifecycle pause is a clean stamp")
	assert_eq(int(stamp["clock_ticks"]), cold.clock.tick_index,
			"doc 13 §3.2's clock_ticks is the generation's own tick index")
	# `manifest.active.real_unix` is `SaveService`'s own `Time` reading, not the
	# lifecycle's injected one, so it is wall-clock NOW rather than T0 — and it
	# was written by two files and read by nobody until this wave.
	assert_true(reader.last_loaded_real_unix > 0,
			"manifest.active.real_unix is read by the shell now, not only written")
	assert_true(reader.last_loaded_max_seen_unix >= reader.last_loaded_real_unix,
			"doc 08 §2.9's monotonic tamper floor comes back with it")
	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()
	reader.free()


func test_a_save_that_never_paused_still_stamps_the_moment_it_was_taken() -> void:
	# A periodic autosave the process was killed two seconds later is just as
	# much a "last time this city was awake" as a pause is.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(12)
	var rig := ClockRig.new()
	var lifecycle := _lifecycle(service, sim, rig)
	service.save_slot(sim, SLOT, "manual")
	var reader := SaveService.new()
	reader.base_dir = TEST_DIR
	assert_true(reader.load_slot(CitySim.boot_from_files(12), SLOT), reader.last_error)
	var stamp := LifecycleStamp.read(reader.last_loaded_android)
	assert_eq(int(stamp["unix_s"]), int(T0))
	assert_false(bool(stamp["clean"]), "…but it is not a CLEAN stamp")
	lifecycle.free()
	service.free()
	reader.free()


# ===========================================================================
# The absence is credited, and it is credited exactly once
# ===========================================================================

func test_a_cold_loaded_city_advances_by_the_stamped_absence() -> void:
	var world := _paused_city(918_442)
	var lifecycle: AndroidLifecycle = world["lifecycle"]
	var service: SaveService = world["service"]

	# The process dies here. A NEW service, a NEW sim, a NEW lifecycle: the only
	# thing that crosses the gap is the generation on disk.
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(918_442)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 + 4.0 * 3600.0     # four real hours later
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	var shell := ShellResumeRig.new()
	shell.setup(cold, cold_service, cold_life)

	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT),
			cold_service.last_error)
	assert_true(cold_life.arm_cold_resume(cold_service),
			"a restored city is owed the absence since its save")
	assert_almost_eq(cold_life.last_cold_elapsed_s, 14_400.0, 0.001)
	var before_ticks := cold.clock.tick_index

	var frames := shell.run_until_settled()
	assert_true(frames > 1, "the catch-up was SLICED, not run in one frame")
	assert_eq(shell.veil_calls.size(), 1, "one absence, one veil")
	assert_eq(cold.clock.tick_index - before_ticks,
			int(shell.veil_calls[0]["total_ticks"]),
			"the city advanced by exactly the plan the veil announced")
	assert_eq(cold.clock.tick_index - before_ticks, 240 * 240,
			"4 real hours = 240 game-hours = 57,600 ticks")
	assert_false(cold_life.owes_resume(), "and it is owed nothing more")

	lifecycle.free()
	service.free()
	cold_life.free()
	cold_service.free()


func test_the_cold_path_and_the_warm_path_land_on_the_SAME_city() -> void:
	# The load-bearing claim. Two cities from the same seed, the same absence,
	# taken through the two different ways of measuring it.
	var absence := 4.0 * 3600.0

	# (a) WARM: never left the process. Pause, four hours pass, RESUMED.
	var warm := _paused_city(4242)
	var warm_sim: CitySim = warm["sim"]
	var warm_life: AndroidLifecycle = warm["lifecycle"]
	var warm_shell: ShellResumeRig = warm["shell"]
	(warm["rig"] as ClockRig).wall += absence
	warm_life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	warm_shell.run_until_settled()

	# (b) COLD: the process died. Same seed, same absence, off the disk.
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(4242)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 + absence
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	var cold_shell := ShellResumeRig.new()
	cold_shell.setup(cold, cold_service, cold_life)
	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT))
	assert_true(cold_life.arm_cold_resume(cold_service))
	cold_shell.run_until_settled()

	assert_eq(cold.clock.tick_index, warm_sim.clock.tick_index)
	assert_eq(cold.clock.residual_game_ms, warm_sim.clock.residual_game_ms)
	assert_eq(cold.state_hash(), warm_sim.state_hash(),
			"a cold launch is a different way of MEASURING the absence and "
			+ "nothing else — the city it produces is bit-identical")

	warm_life.free()
	(warm["service"] as SaveService).free()
	cold_life.free()
	cold_service.free()


func test_the_absence_is_credited_once_however_many_frames_run() -> void:
	var world := _paused_city(77)
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(77)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 + 3_600.0
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	var shell := ShellResumeRig.new()
	shell.setup(cold, cold_service, cold_life)
	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT))
	assert_true(cold_life.arm_cold_resume(cold_service))
	shell.run_until_settled()
	var settled := cold.state_hash()
	for _i in 200:
		shell.process_frame()
	assert_eq(cold.state_hash(), settled, "a spent absence is not spent twice")
	assert_eq(shell.veil_calls.size(), 1)
	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()
	cold_life.free()
	cold_service.free()


# ===========================================================================
# What owes NOTHING
# ===========================================================================

func test_a_fresh_city_owes_zero() -> void:
	# No save, so no stamp and no manifest — a founding city cannot be behind.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(5)
	var rig := ClockRig.new()
	rig.wall = T0 + 99_999.0
	var lifecycle := _lifecycle(service, sim, rig)
	assert_false(lifecycle.arm_cold_resume(service),
			"a city that was never saved owes nothing")
	assert_eq(lifecycle.last_cold_elapsed_s, 0.0)
	assert_eq(lifecycle.last_cold_anomaly, LifecycleStamp.ANOMALY_NO_STAMP)
	lifecycle.free()
	service.free()


func test_a_clock_that_moved_backwards_owes_zero_and_says_so() -> void:
	var world := _paused_city(9)
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(9)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 - 7_200.0        # the device clock went back two hours
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	var shell := ShellResumeRig.new()
	shell.setup(cold, cold_service, cold_life)
	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT))
	var ticks := cold.clock.tick_index

	assert_false(cold_life.arm_cold_resume(cold_service),
			"doc 08 §2.9: elapsed credits zero. We clamp; we never punish")
	assert_eq(cold_life.last_cold_anomaly, LifecycleStamp.ANOMALY_BACKWARDS)
	shell.run_until_settled()
	assert_eq(cold.clock.tick_index, ticks, "and the city did not move")
	assert_true(shell.veil_calls.is_empty(), "no veil for an absence of nothing")

	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()
	cold_life.free()
	cold_service.free()


func test_an_absence_under_a_second_arms_nothing() -> void:
	var world := _paused_city(6)
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(6)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 + 0.4
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT))
	assert_false(cold_life.arm_cold_resume(cold_service))
	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()
	cold_life.free()
	cold_service.free()


# ===========================================================================
# The title door
# ===========================================================================

func test_the_title_door_s_CONTINUE_pays_the_same_absence() -> void:
	# Doc 12 §2.19's door is the DEFAULT launch path — `_want_title` is true on
	# every clean player launch — and it was the worst case of the P0: the boot
	# never loaded at all, and `_on_app_resumed` bailed on `_title_up` anyway. So
	# a player who left overnight and pressed CONTINUE got a frozen city with no
	# report and no veil.
	var world := _paused_city(1234)
	var cold_service := SaveService.new()
	cold_service.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(1234)
	var cold_rig := ClockRig.new()
	cold_rig.wall = T0 + 6.0 * 3600.0
	var cold_life := _lifecycle(cold_service, cold, cold_rig)
	var shell := ShellResumeRig.new()
	shell.setup(cold, cold_service, cold_life)

	# The door is up: the founding city idles underneath, saves stand down, and
	# a resume that arrived now would be dropped.
	shell.title_up = true
	shell.paused = true
	cold_life.save_enabled = false
	cold_life.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	shell.process_frame()
	assert_true(shell.veil_calls.is_empty(), "nothing runs behind the door")

	# CONTINUE. `Main._advance_restore`'s tail, as the snippet writes it.
	assert_true(cold_service.load_slot(cold, SaveService.AUTOSAVE_SLOT))
	var ticks := cold.clock.tick_index
	shell.paused = false
	shell.title_up = false
	cold_life.save_enabled = true
	if cold_life.arm_cold_resume(cold_service):
		cold_life.pump_resume()
	shell.run_until_settled()

	assert_eq(shell.veil_calls.size(), 1, "the door's CONTINUE raises the veil")
	assert_eq(cold.clock.tick_index - ticks, 360 * 240,
			"6 real hours = 360 game-hours of catch-up")
	assert_eq(shell.reports.size(), 1, "and the player gets the away report")
	var report: Dictionary = shell.reports[0]
	assert_almost_eq(float(report["elapsed_wall_s"]), 21_600.0, 0.001)
	assert_true(int((report["before"] as Dictionary)["day_index"])
			< int((report["after"] as Dictionary)["day_index"]),
			"the 'before' is the city as the door found it")

	(world["lifecycle"] as AndroidLifecycle).free()
	(world["service"] as SaveService).free()
	cold_life.free()
	cold_service.free()


# ===========================================================================
# Saves written before this wave
# ===========================================================================

func test_a_generation_with_no_android_section_falls_back_to_the_manifest() -> void:
	# Every save ever written before Wave 17 has `manifest.active.real_unix` and
	# no `save.android`. It is a wall reading with no bracket — the same
	# information desktop has always had — and it is credited on those terms.
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(31)
	service.save_slot(sim, SLOT, "autosave")        # no android_provider set
	var reader := SaveService.new()
	reader.base_dir = TEST_DIR
	var cold := CitySim.boot_from_files(31)
	assert_true(reader.load_slot(cold, SLOT), reader.last_error)
	assert_true(LifecycleStamp.read(reader.last_loaded_android).is_empty(),
			"the fixture really has no stamp")
	assert_true(reader.last_loaded_real_unix > 0)

	var rig := ClockRig.new()
	rig.wall = float(reader.last_loaded_real_unix) + 7_200.0
	var lifecycle := _lifecycle(reader, cold, rig)
	assert_true(lifecycle.arm_cold_resume(reader))
	assert_almost_eq(lifecycle.last_cold_elapsed_s, 7_200.0, 1.0)
	lifecycle.free()
	service.free()
	reader.free()
