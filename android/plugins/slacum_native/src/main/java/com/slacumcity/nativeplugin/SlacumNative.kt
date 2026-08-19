package com.slacumcity.nativeplugin

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File

/**
 * `SlacumNative` — the Slacum City Android plugin (design doc 13 §2.6), v1 scope.
 *
 * Bounded on purpose: this class contains **no game logic, no policy and no
 * strings**. GDScript decides *what* and *when*; Kotlin only knows *how*. That
 * keeps the surface that cannot be tested headlessly as small as it can be.
 *
 * Three capabilities ship here, and nothing else:
 *
 *  1. **`elapsed_realtime_ms()`** — `SystemClock.elapsedRealtime()`, which keeps
 *     counting while the device is in deep sleep. Godot's `Time.get_ticks_msec()`
 *     is `CLOCK_MONOTONIC`, which **stalls** in deep sleep, so it can only ever be
 *     a *lower* bound on how long the player was away. `elapsedRealtime` is the
 *     missing *upper* bound that lets `AndroidLifecycle` reject a wall clock that
 *     jumped forward (NTP correction, manual clock change, timezone rollover)
 *     without punishing an honest 12-hour absence.
 *  2. **`boot_id()`** — `elapsedRealtime` resets to ~0 on reboot, so it may only be
 *     compared across a pause/resume pair that stayed inside one boot. The kernel's
 *     random boot id names the boot; a mismatch means "reboot happened, ignore the
 *     monotonic cross-check and trust the wall clock".
 *  3. **Thermal + sustained performance** — `PowerManager.getCurrentThermalStatus()`
 *     (API 29, exactly our minSdk) plus a push listener, and the window's sustained
 *     performance mode, which asks the SoC for a level it can hold indefinitely
 *     rather than a boost it must throttle out of. A city builder is played in long
 *     sessions; a stable 60 fps beats a fast three minutes and a hot phone.
 *
 * Notifications, permissions and the alarm registry are deliberately NOT here yet —
 * they are Milestone B (doc 13 §6) and would triple this file.
 */
class SlacumNative(godot: Godot) : GodotPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "SlacumNative"
		private const val TAG = PLUGIN_NAME

		/** Emitted on every thermal transition; payload is `THERMAL_STATUS_*` (0..6). */
		private const val SIGNAL_THERMAL_STATUS_CHANGED = "thermal_status_changed"

		/** Randomised per boot by the kernel, world-readable, no permission needed. */
		private const val BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"

		/** Returned by every accessor that has no platform answer to give. */
		private const val UNKNOWN_STATUS = -1
	}

	// Context, not activity: the power service has nothing to do with the window,
	// and a Godot host that is a fragment rather than an activity still has one.
	private val powerManager: PowerManager?
		get() = (context ?: activity)?.getSystemService(Context.POWER_SERVICE) as? PowerManager

	/** Read once — the boot id cannot change without the process dying with it. */
	private val cachedBootId: String by lazy { readBootId() }

	private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo(SIGNAL_THERMAL_STATUS_CHANGED, Integer::class.java)
	)

	override fun onGodotSetupCompleted() {
		super.onGodotSetupCompleted()
		registerThermalListener()
	}

	override fun onMainDestroy() {
		unregisterThermalListener()
		super.onMainDestroy()
	}

	// ------------------------------------------------------------------ time

	/**
	 * Milliseconds since boot, **including deep sleep** — the clock Godot cannot
	 * reach. Only comparable against a reading taken during the same boot, which
	 * is what [boot_id] is for.
	 */
	@UsedByGodot
	fun elapsed_realtime_ms(): Long = SystemClock.elapsedRealtime()

	/** Kernel boot id, or `""` if it could not be read (then skip the cross-check). */
	@UsedByGodot
	fun boot_id(): String = cachedBootId

	// --------------------------------------------------------------- thermal

	/**
	 * `PowerManager.THERMAL_STATUS_*`: 0 NONE, 1 LIGHT, 2 MODERATE, 3 SEVERE,
	 * 4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN. Returns -1 when the service is
	 * unavailable — the caller must treat that as "no opinion", not as NONE.
	 */
	@UsedByGodot
	fun thermal_status(): Int = powerManager?.currentThermalStatus ?: UNKNOWN_STATUS

	// ---------------------------------------------------- sustained performance

	/** False on devices that cannot hold a performance level (most mid-range SoCs). */
	@UsedByGodot
	fun is_sustained_performance_supported(): Boolean =
		powerManager?.isSustainedPerformanceModeSupported ?: false

	/**
	 * Ask the platform for a clock level it can sustain indefinitely. Silently
	 * ignored by devices that do not support it, which is why this returns
	 * nothing — [is_sustained_performance_supported] is the honest answer.
	 * `Window` is UI-thread-only, hence the hop onto the host thread.
	 */
	@UsedByGodot
	fun set_sustained_performance(on: Boolean) {
		val currentActivity = activity ?: return
		runOnHostThread {
			try {
				currentActivity.window.setSustainedPerformanceMode(on)
			} catch (e: Exception) {
				Log.w(TAG, "sustained performance mode refused: ${e.message}")
			}
		}
	}

	// ---------------------------------------------------------------- internals

	private fun registerThermalListener() {
		val manager = powerManager ?: return
		if (thermalListener != null) {
			return
		}
		val listener = PowerManager.OnThermalStatusChangedListener { status ->
			emitSignal(SIGNAL_THERMAL_STATUS_CHANGED, status)
		}
		try {
			manager.addThermalStatusListener(listener)
			thermalListener = listener
		} catch (e: Exception) {
			Log.w(TAG, "thermal listener refused: ${e.message}")
		}
	}

	private fun unregisterThermalListener() {
		val listener = thermalListener ?: return
		thermalListener = null
		try {
			powerManager?.removeThermalStatusListener(listener)
		} catch (e: Exception) {
			Log.w(TAG, "thermal listener removal refused: ${e.message}")
		}
	}

	private fun readBootId(): String = try {
		File(BOOT_ID_PATH).readText().trim()
	} catch (e: Exception) {
		Log.w(TAG, "boot id unreadable: ${e.message}")
		""
	}
}
