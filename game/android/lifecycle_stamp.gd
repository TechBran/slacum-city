class_name LifecycleStamp
extends RefCounted
## Doc 13 §3.2's `save.android.last_pause`: what the city knows about the moment
## it was last committed, and the arithmetic that turns it into an absence.
##
## **Why this file exists (report 98 §48, RR-132).** Doc 08's Core Rule 2 says a
## city keeps running while the player is away. Until Wave 17 that was true on
## exactly one path — `NOTIFICATION_APPLICATION_RESUMED` reaching a process that
## was still alive. `AndroidLifecycle._paused_wall` was an in-memory member,
## `-1.0` at every boot and never seeded from disk, so after a process death, a
## swipe-away, or the title door's CONTINUE the city resumed **frozen at the
## pause**: the most common Android path, and the one Core Rule 2 was written
## for. The stamp below is the missing half — the pause moment, written into the
## save beside the city, so a launch that never saw the pause can still measure
## the absence.
##
## The class is PURE: it reads no clock and touches no file. Every reading is an
## argument, which is what makes `tests/test_lifecycle_stamp.gd` able to drive a
## reboot, a clock rollback and an NTP jump without a device.
##
## Doc 13 §3.2's field list is `{unix_s, elapsed_realtime_ms, boot_id,
## clock_ticks, app_version, clean}`; `unfinished` is Wave 17's addition and is
## the unspent tail of a catch-up the process died in the middle of (RR-134).

## `save.android`'s own ladder rung (doc 08 §2.8, RR-75 — a new section starts
## at 1 and owes no epoch marker).
const SECTION_VERSION := 1

## A wall-clock reading further behind its bracket than this is a clock change,
## not elapsed time. The same 120 s doc 13 §2.3 and `AndroidLifecycle` already
## use, for the same reason: the two clocks are sampled milliseconds apart and
## neither is a stopwatch.
const CLOCK_TOLERANCE_S := 120.0

## `elapsed_since` outcomes, in `anomaly`.
const ANOMALY_NONE := ""
## No usable stamp: a founding city, or a save written before this wave with no
## `manifest.active.real_unix` either. Owes zero, and that is not a fault.
const ANOMALY_NO_STAMP := "no_stamp"
## Doc 08 §2.9: `now_unix < max_seen_unix`. The device clock moved backwards;
## elapsed credits zero. We clamp; we never punish.
const ANOMALY_BACKWARDS := "clock_backwards"
## The wall clock claimed more time than `elapsedRealtime` allows within one
## boot (NTP, timezone, a manual change). The monotonic ceiling wins.
const ANOMALY_FORWARD := "clock_forward"
## The device rebooted while away and the wall clock claims LESS time than the
## device has been up since that reboot. Time since boot is a hard floor on an
## absence that began before it, so the floor wins.
const ANOMALY_SHORT := "clock_short"


## Build the section body a pause save carries. `elapsed_realtime_ms` and
## `boot_id` are the plugin's, and `-1` / `""` mean "no plugin", which disables
## the cross-check on the way back in rather than inventing one.
static func build(unix_s: int, elapsed_realtime_ms: int, boot_id: String,
		clock_ticks: int, app_version: String, clean: bool,
		unfinished: Dictionary = {}) -> Dictionary:
	var stamp := {
		"unix_s": maxi(0, unix_s),
		"elapsed_realtime_ms": elapsed_realtime_ms if elapsed_realtime_ms >= 0 else -1,
		"boot_id": boot_id,
		"clock_ticks": maxi(0, clock_ticks),
		"app_version": app_version,
		"clean": clean,
	}
	if not unfinished.is_empty():
		stamp["unfinished"] = unfinished
	return stamp


## The stamp out of a loaded `save.android` section, normalised, or `{}` when
## there is none. Total by contract: a section from a build that wrote a
## different shape comes back as far as it parses and no further.
static func read(section: Dictionary) -> Dictionary:
	var raw: Variant = section.get("last_pause", null)
	if not (raw is Dictionary):
		return {}
	var stamp: Dictionary = raw
	var unix_s := int(stamp.get("unix_s", 0))
	if unix_s <= 0:
		return {}
	var unfinished: Variant = stamp.get("unfinished", {})
	return {
		"unix_s": unix_s,
		"elapsed_realtime_ms": int(stamp.get("elapsed_realtime_ms", -1)),
		"boot_id": String(stamp.get("boot_id", "")),
		"clock_ticks": int(stamp.get("clock_ticks", 0)),
		"app_version": String(stamp.get("app_version", "")),
		"clean": bool(stamp.get("clean", false)),
		"unfinished": unfinished if unfinished is Dictionary else {},
	}


## A stamp built from nothing but `manifest.active.real_unix` — the fallback for
## every generation written before this wave, and for a save committed by a path
## that never paused. It has the wall reading and nothing else, so the
## reconciliation below runs on the floor/ceiling it has, which is none.
static func from_manifest_unix(real_unix: int) -> Dictionary:
	if real_unix <= 0:
		return {}
	return {"unix_s": real_unix, "elapsed_realtime_ms": -1, "boot_id": "",
			"clock_ticks": 0, "app_version": "", "clean": false, "unfinished": {}}


## THE COLD-LAUNCH ABSENCE (doc 08 §2.9, doc 13 §3.2).
##
## Returns `{elapsed_s: float, anomaly: String, cross_checked: bool}`.
##
## Three readings, in the order they are allowed to overrule each other:
##
## 1. **`max_seen_unix` — doc 08 §2.9's monotonic tamper gate, and it is
##    absolute.** If now is behind the newest wall time this city has ever been
##    saved at (beyond the tolerance), the clock moved backwards: elapsed credits
##    **zero**, and nothing below gets to raise it. A player who set the clock
##    back does not get a negative city and does not get a punished one.
## 2. **`elapsedRealtime` within ONE boot — the ceiling.** It counts through deep
##    sleep, so it measures the absence exactly and a wall delta above it is a
##    clock that jumped forward. Only comparable when the boot ids match and are
##    both known; `""` is never "same boot" (`AndroidNative.boot_id`'s own rule).
## 3. **`elapsedRealtime` across a REBOOT — the floor.** Different boot ids mean
##    the device restarted *during* the absence, so the absence is at least as
##    long as the device has been up. A wall clock that claims less than that has
##    lost time, and the floor wins.
##
## Off device (`now_realtime_ms < 0`, or either boot id unknown) only step 1
## applies, which is exactly the desktop and headless-runner behaviour.
static func elapsed_since(stamp: Dictionary, now_unix: float, now_realtime_ms: int,
		now_boot_id: String, max_seen_unix: int) -> Dictionary:
	var at := int(stamp.get("unix_s", 0))
	if at <= 0:
		return {"elapsed_s": 0.0, "anomaly": ANOMALY_NO_STAMP, "cross_checked": false}
	var floor_unix := maxi(max_seen_unix, at)
	if now_unix + CLOCK_TOLERANCE_S < float(floor_unix):
		return {"elapsed_s": 0.0, "anomaly": ANOMALY_BACKWARDS, "cross_checked": false}
	var elapsed := maxf(0.0, now_unix - float(at))
	var anomaly := ANOMALY_NONE
	var cross_checked := false

	var was_realtime := int(stamp.get("elapsed_realtime_ms", -1))
	var was_boot := String(stamp.get("boot_id", ""))
	if now_realtime_ms >= 0 and was_boot != "" and now_boot_id != "":
		if was_boot == now_boot_id:
			if was_realtime >= 0 and now_realtime_ms >= was_realtime:
				cross_checked = true
				var ceiling := float(now_realtime_ms - was_realtime) / 1000.0 \
						+ CLOCK_TOLERANCE_S
				if elapsed > ceiling:
					anomaly = ANOMALY_FORWARD
					elapsed = ceiling
		else:
			# A reboot. `elapsedRealtime` restarted, so it is no ceiling any more
			# — but the device cannot have been up longer than the app has been
			# away, because the pause happened before the reboot.
			cross_checked = true
			var floor_s := float(now_realtime_ms) / 1000.0
			if elapsed + CLOCK_TOLERANCE_S < floor_s:
				anomaly = ANOMALY_SHORT
				elapsed = floor_s
	return {"elapsed_s": elapsed, "anomaly": anomaly, "cross_checked": cross_checked}
