extends SimTest
## The `SlacumNative` half of the lifecycle (doc 13 §2.3 / §2.6): the
## `elapsedRealtime` ceiling on a measured absence, and the thermal forwarding.
##
## The plugin itself is Kotlin and cannot run here, so these tests do what the
## bridge was shaped for: substitute a fake `AndroidNative`. The save layer is
## deliberately left unwired — nothing here writes to `user://`, so the suite
## stays safe to run beside another agent's.

const HOUR_S := 3600.0


## A `SlacumNative` that is present and answers from fields the test drives.
class FakeNative extends AndroidNative:
	var available := true
	var realtime_ms: int = 10_000
	var boot := "boot-a"

	func is_available() -> bool:
		return available

	func elapsed_realtime_ms() -> int:
		return realtime_ms

	func boot_id() -> String:
		return boot


class ClockRig extends RefCounted:
	var wall: float = 1_800_000_000.0
	var mono: float = 100.0

	func wall_now() -> float:
		return wall

	func mono_now() -> float:
		return mono


func _rigged(rig: ClockRig, fake: AndroidNative) -> AndroidLifecycle:
	var lifecycle := AndroidLifecycle.new()
	lifecycle.wall_clock = rig.wall_now
	lifecycle.mono_clock = rig.mono_now
	lifecycle.native = fake
	return lifecycle


# ------------------------------------------------------- the ceiling applies

func test_wall_clock_jump_is_capped_by_elapsed_realtime() -> void:
	# Doc 13 §2.3 case A-02: away for 10 real minutes, but the wall clock jumped
	# a day forward while the app was backgrounded.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall += 86_400.0
	rig.mono += 5.0          # device slept: CLOCK_MONOTONIC barely moved
	fake.realtime_ms += 600_000  # elapsedRealtime knows it was 10 minutes
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s,
			600.0 + AndroidLifecycle.CLOCK_TOLERANCE_S, 0.001,
			"the ceiling is elapsedRealtime plus the sampling tolerance")
	assert_eq(lifecycle.last_anomaly, "clock_forward")
	assert_true(lifecycle.last_cross_checked)
	lifecycle.free()


func test_honest_twelve_hour_absence_is_not_truncated() -> void:
	# The whole risk of a ceiling is that it eats a legitimate long absence.
	# 12 real hours away, deep sleep throughout: elapsedRealtime agrees with the
	# wall clock and the measurement passes through untouched.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall += 12.0 * HOUR_S
	rig.mono += 30.0
	fake.realtime_ms += int(12.0 * HOUR_S * 1000.0) - 10_000  # 10 s of skew
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s, 43_200.0, 0.001,
			"an honest 12 h absence survives the cross-check intact")
	assert_eq(lifecycle.last_anomaly, "")
	assert_true(lifecycle.last_cross_checked)
	lifecycle.free()


# ---------------------------------------------------- the ceiling stands down

func test_reboot_while_away_disables_the_cross_check() -> void:
	# Doc 13 §2.3 case A-04: elapsedRealtime restarts at ~0 on reboot, so the
	# boot id mismatch must make the wall clock authoritative again. Trusting
	# the reading instead would report a three-day absence as four minutes.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	fake.realtime_ms = 9_000_000
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall += 3.0 * 86_400.0
	rig.mono += 20.0
	fake.boot = "boot-b"
	fake.realtime_ms = 240_000
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s, 259_200.0, 0.001,
			"across a reboot the wall clock is all there is")
	assert_eq(lifecycle.last_anomaly, "")
	assert_false(lifecycle.last_cross_checked)
	lifecycle.free()


func test_backwards_clock_still_falls_back_to_monotonic() -> void:
	# The floor outranks the ceiling: a backwards jump is decided before the
	# plugin is consulted at all, exactly as it was before the plugin existed.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall -= HOUR_S
	rig.mono += 600.0
	fake.realtime_ms += 600_000
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s, 600.0, 0.001)
	assert_eq(lifecycle.last_anomaly, "clock_backwards")
	assert_false(lifecycle.last_cross_checked)
	lifecycle.free()


func test_unreadable_boot_id_disables_the_cross_check() -> void:
	# "" is not a boot id. Treating it as one would make every device with a
	# locked-down /proc share a boot with itself across reboots.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	fake.boot = ""
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall += 86_400.0
	rig.mono += 5.0
	fake.realtime_ms += 600_000
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s, 86_400.0, 0.001)
	assert_false(lifecycle.last_cross_checked)
	lifecycle.free()


func test_without_the_plugin_nothing_changes() -> void:
	# Desktop and the headless runner: the bridge exists, reports unavailable,
	# and the measurement is the plugin-free one.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	fake.available = false
	var lifecycle := _rigged(rig, fake)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)

	rig.wall += 5400.0
	rig.mono += 12.0
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)

	assert_almost_eq(lifecycle.last_elapsed_wall_s, 5400.0, 0.001)
	assert_eq(lifecycle.last_anomaly, "")
	assert_false(lifecycle.last_cross_checked)
	lifecycle.free()


func test_real_bridge_is_unavailable_off_device() -> void:
	# The Engine.has_singleton guard is the only thing standing between the
	# desktop build and a crash, so assert it directly.
	var bridge := AndroidNative.detect()
	assert_false(bridge.is_available(), "no SlacumNative singleton off-device")
	assert_eq(bridge.elapsed_realtime_ms(), -1)
	assert_eq(bridge.boot_id(), "")
	assert_eq(bridge.thermal_status(), AndroidNative.THERMAL_UNKNOWN)
	assert_false(bridge.is_sustained_performance_supported())
	bridge.set_sustained_performance(true)  # must be a no-op, not a crash


# -------------------------------------------------------------------- thermal

func test_thermal_status_is_forwarded_and_remembered() -> void:
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	var lifecycle := _rigged(rig, fake)
	assert_eq(lifecycle.last_thermal_status, AndroidNative.THERMAL_UNKNOWN,
			"no reading has arrived yet")
	lifecycle.bind_native()

	var seen: Array[int] = []
	lifecycle.thermal_status_changed.connect(func(s: int) -> void: seen.append(s))
	fake.thermal_status_changed.emit(3)   # SEVERE
	fake.thermal_status_changed.emit(1)   # LIGHT

	assert_eq(seen, [3, 1] as Array[int])
	assert_eq(lifecycle.last_thermal_status, 1)
	lifecycle.free()


func test_binding_twice_does_not_double_forward() -> void:
	# `_ready` binds, and a caller may bind again after swapping the bridge.
	var rig := ClockRig.new()
	var fake := FakeNative.new()
	var lifecycle := _rigged(rig, fake)
	lifecycle.bind_native()
	lifecycle.bind_native()

	var seen: Array[int] = []
	lifecycle.thermal_status_changed.connect(func(s: int) -> void: seen.append(s))
	fake.thermal_status_changed.emit(2)

	assert_eq(seen, [2] as Array[int])
	lifecycle.free()
