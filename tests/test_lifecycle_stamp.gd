extends SimTest
## Doc 13 §3.2's pause stamp and the absence it measures on a COLD launch
## (report 98 §48, RR-132).
##
## `LifecycleStamp` reads no clock and opens no file — every reading is an
## argument — so a reboot, an NTP jump backwards, an NTP jump forwards and a
## missing plugin are all four expressible here without a device, which is the
## whole reason the arithmetic was pulled out of `AndroidLifecycle`.
##
## The numbers below are the ones doc 13 §2.9 and doc 08 §2.9 argue about:
## `unix_s` is a wall reading, `elapsed_realtime_ms` is `SystemClock`'s
## boot-relative one, and `boot_id` is what decides which of the two is allowed
## to overrule the other.

const BOOT_A := "3f2ac19"
const BOOT_B := "91be4d0"
const T0 := 1_800_000_000


func _stamp(unix_s: int = T0, realtime_ms: int = 88_000_000,
		boot: String = BOOT_A) -> Dictionary:
	return LifecycleStamp.build(unix_s, realtime_ms, boot, 49_920, "0.4.0", true)


func test_build_carries_doc13_section_32_fields() -> void:
	var stamp := _stamp()
	assert_eq(stamp["unix_s"], T0)
	assert_eq(stamp["elapsed_realtime_ms"], 88_000_000)
	assert_eq(String(stamp["boot_id"]), BOOT_A)
	assert_eq(stamp["clock_ticks"], 49_920)
	assert_eq(String(stamp["app_version"]), "0.4.0")
	assert_true(bool(stamp["clean"]))
	assert_false(stamp.has("unfinished"),
			"an unfinished plan is only carried when there IS one")


func test_read_round_trips_a_written_section() -> void:
	var section := {"section_version": LifecycleStamp.SECTION_VERSION,
			"last_pause": _stamp()}
	var back := LifecycleStamp.read(section)
	assert_eq(back["unix_s"], T0)
	assert_eq(String(back["boot_id"]), BOOT_A)
	assert_true((back["unfinished"] as Dictionary).is_empty())


func test_read_of_a_save_that_predates_the_section_is_empty() -> void:
	assert_true(LifecycleStamp.read({}).is_empty(),
			"a generation written before Wave 17 has no android section")
	assert_true(LifecycleStamp.read({"last_pause": {"unix_s": 0}}).is_empty(),
			"a stamp with no wall reading is not a stamp")


# ------------------------------------------------------------ the absence

func test_a_cold_launch_credits_the_wall_delta() -> void:
	# Eight hours away, no plugin (desktop / the headless runner): only the
	# wall clock exists, and it is believed.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, -1, ""),
			float(T0 + 8 * 3600), -1, "", T0)
	assert_almost_eq(float(out["elapsed_s"]), 28_800.0, 0.001)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_NONE)
	assert_false(bool(out["cross_checked"]))


func test_no_stamp_owes_nothing() -> void:
	var out := LifecycleStamp.elapsed_since({}, float(T0 + 9_999), -1, "", 0)
	assert_eq(float(out["elapsed_s"]), 0.0)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_NO_STAMP)


func test_clock_backwards_credits_zero_against_max_seen_unix() -> void:
	# Doc 08 §2.9: `max_seen_unix` is monotonic. The stamp says T0, the newest
	# save this city ever took was an hour later, and the device now claims
	# earlier than BOTH. We clamp; we never punish.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, -1, ""),
			float(T0 - 7_200), -1, "", T0 + 3_600)
	assert_eq(float(out["elapsed_s"]), 0.0)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_BACKWARDS)


func test_a_clock_nudged_back_inside_the_tolerance_is_not_a_rollback() -> void:
	# 60 s of NTP correction is not a tamper; doc 13 §2.3's 120 s tolerance is
	# the same one the in-process path has always used.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, -1, ""),
			float(T0 - 60), -1, "", T0)
	assert_eq(float(out["elapsed_s"]), 0.0, "still zero — but not a rollback")
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_NONE)


func test_elapsed_realtime_is_the_ceiling_within_one_boot() -> void:
	# The wall clock claims 30 real hours; `SystemClock.elapsedRealtime()` says
	# only 2 h + 1 s have passed since the pause, and the boot id has not moved,
	# so the clock jumped forward and the monotonic ceiling wins.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, 88_000_000, BOOT_A),
			float(T0 + 30 * 3600), 88_000_000 + 7_201_000, BOOT_A, T0)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_FORWARD)
	assert_true(bool(out["cross_checked"]))
	assert_almost_eq(float(out["elapsed_s"]),
			7_201.0 + LifecycleStamp.CLOCK_TOLERANCE_S, 0.001)


func test_a_wall_delta_under_the_ceiling_is_left_alone() -> void:
	var out := LifecycleStamp.elapsed_since(_stamp(T0, 88_000_000, BOOT_A),
			float(T0 + 3_600), 88_000_000 + 3_601_000, BOOT_A, T0)
	assert_almost_eq(float(out["elapsed_s"]), 3_600.0, 0.001)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_NONE)
	assert_true(bool(out["cross_checked"]))


func test_a_reboot_turns_elapsed_realtime_into_a_FLOOR() -> void:
	# Doc 13 §3.2: `elapsedRealtime` restarts at ~0 on reboot, so the boot id
	# decides. Different boot ⇒ the device restarted DURING the absence, so the
	# absence is at least as long as the device has been up — and here the wall
	# clock claims 10 minutes while the device has been up for 3 hours.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, 88_000_000, BOOT_A),
			float(T0 + 600), 10_800_000, BOOT_B, T0)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_SHORT)
	assert_almost_eq(float(out["elapsed_s"]), 10_800.0, 0.001)
	assert_true(bool(out["cross_checked"]))


func test_a_reboot_does_not_truncate_a_longer_absence() -> void:
	# The other side of the same rule: up for 3 hours, away for 30. The floor is
	# a floor, not a ceiling.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, 88_000_000, BOOT_A),
			float(T0 + 30 * 3600), 10_800_000, BOOT_B, T0)
	assert_almost_eq(float(out["elapsed_s"]), 108_000.0, 0.001)
	assert_eq(String(out["anomaly"]), LifecycleStamp.ANOMALY_NONE)


func test_an_unknown_boot_id_is_never_the_same_boot() -> void:
	# `AndroidNative.boot_id()`'s own rule, applied here: "" disables the
	# cross-check rather than pretending the boot matched.
	var out := LifecycleStamp.elapsed_since(_stamp(T0, 88_000_000, ""),
			float(T0 + 30 * 3600), 88_000_100, BOOT_A, T0)
	assert_false(bool(out["cross_checked"]))
	assert_almost_eq(float(out["elapsed_s"]), 108_000.0, 0.001)


func test_an_unfinished_plan_rides_the_stamp() -> void:
	var tail := {"segments": [{"kind": "coarse", "count": 5,
			"index_base": 2, "total": 7}], "total_ticks": 1200}
	var stamp := LifecycleStamp.build(T0, -1, "", 0, "0.4.0", true, tail)
	var back := LifecycleStamp.read({"last_pause": stamp})
	assert_eq(int((back["unfinished"] as Dictionary)["total_ticks"]), 1200)
