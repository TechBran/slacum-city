package com.slacumcity.nativeplugin

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.Surface
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * `SlacumNative` — the Slacum City Android plugin (design doc 13 §2.6).
 *
 * Bounded on purpose: this class contains **no game logic, no policy and no
 * strings**. GDScript decides *what* and *when*; Kotlin only knows *how*. That
 * keeps the surface that cannot be tested headlessly as small as it can be — and
 * it is why the rate limiter, the quiet-hours window and the class table are
 * nowhere in this file (report C-71: everything that arrives here has already
 * passed doc 08's budget and is final).
 *
 * Four capabilities ship:
 *
 *  1. **Time** — `elapsed_realtime_ms()` (`SystemClock.elapsedRealtime()`, which
 *     keeps counting through deep sleep where Godot's `CLOCK_MONOTONIC` stalls) and
 *     `boot_id()`, without which two readings from different boots would be
 *     subtracted from each other and a three-day absence would measure four minutes.
 *  2. **Thermal + sustained performance** — `getCurrentThermalStatus()` (API 29,
 *     exactly our minSdk) plus a push listener, and the window's sustained
 *     performance mode: a clock the SoC can hold beats a boost it must throttle
 *     out of, in a game played in half-hour sittings.
 *  3. **Notifications** (Milestone B, doc 13 §2.4/§2.5) — channels, immediate posts,
 *     `AlarmManager` schedules, cancellation and the reboot registry, all in
 *     [NotificationCenter].
 *  4. **The `POST_NOTIFICATIONS` runtime flow** (doc 13 §2.7) — request, state
 *     reporting and a route into system settings for the permanently-denied case.
 *     The *when* is GDScript's (`game/notifications/permission_flow.gd`); this side
 *     only knows how to ask and how to report what the system said.
 *  5. **Launch arguments** (doc 13 D-20) — [launch_args] hands GDScript whatever
 *     the launching Intent actually carried, because the export template does not
 *     forward `--esa command_line_params` into `OS.get_cmdline_user_args()` on
 *     this build. Reading the extra is a *how*; what an argument MEANS stays in
 *     `game/dev_args.gd` and `game/main.gd`.
 *  6. **The refresh pin** (doc 13 §2.8, report 98 RR-126) — [set_frame_rate]
 *     DECLARES the rate the app intends to present at, and
 *     [get_supported_refresh_rates] reports what the panel can actually do. The
 *     app caps `Engine.max_fps` and never told the display about it; on an LTPO
 *     panel that leaves the platform inferring a mode from observed cadence.
 *     Which rate to declare is policy and stays in `game/render/refresh_pin.gd`;
 *     this side only knows how to say it to `Surface` and to the window.
 */
class SlacumNative(godot: Godot) : GodotPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "SlacumNative"
		private const val TAG = PLUGIN_NAME

		/** Emitted on every thermal transition; payload is `THERMAL_STATUS_*` (0..6). */
		private const val SIGNAL_THERMAL_STATUS_CHANGED = "thermal_status_changed"
		/** `POST_NOTIFICATIONS` came back: true = granted. */
		private const val SIGNAL_PERMISSION_RESULT = "permission_result"
		/** A scheduled notification actually fired while the process was alive. */
		private const val SIGNAL_NOTIFICATION_DELIVERED = "notification_delivered"
		/** The player tapped a notification and it brought the app up: payload string. */
		private const val SIGNAL_NOTIFICATION_OPENED = "notification_opened"

		/** Randomised per boot by the kernel, world-readable, no permission needed. */
		private const val BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"

		/**
		 * The string-ARRAY extra Godot's own Android launcher is documented to read
		 * as the process command line, and the one `adb shell am start --esa` puts
		 * there. We read it a second time, from the Intent, because on this export
		 * template it never reaches `OS.get_cmdline_user_args()` (doc 13 D-20).
		 */
		private const val EXTRA_COMMAND_LINE = "command_line_params"

		/**
		 * A plain string extra, for the `adb` invocation nobody gets wrong:
		 * `--es args "--resume --zoom=1.0"`. Split on whitespace here because that
		 * is marshalling, not meaning.
		 */
		private const val EXTRA_ARGS = "args"

		/** Returned by every accessor that has no platform answer to give. */
		private const val UNKNOWN_STATUS = -1

		/**
		 * How far a panel's published refresh rate may sit from a whole multiple
		 * of the target and still count as one. Half a hertz: it swallows the
		 * 59.94-style rates a panel may report and nothing else — 60 against a
		 * 45 fps target misses by 15 Hz and is never mistaken for a multiple.
		 */
		private const val RATE_EPSILON_HZ = 0.5

		private const val PERMISSION_REQUEST_CODE = 7301
		private const val PREFS = "slacum_native"
		private const val PREF_ASKED = "post_notifications_asked"

		const val STATE_GRANTED = "granted"
		const val STATE_DENIED = "denied"
		const val STATE_DENIED_PERMANENT = "denied_permanent"
		const val STATE_NEVER_ASKED = "never_asked"
		const val STATE_UNSUPPORTED = "unsupported"

		/**
		 * The live plugin, or null when the process is dead — which is the normal
		 * case for [AlarmReceiver], since scheduling notifications for a closed app
		 * is the whole feature. Weak-by-nulling rather than a `WeakReference`
		 * because the lifetime is explicit: set at setup, cleared at destroy.
		 */
		@Volatile
		private var live: SlacumNative? = null

		/** Called by [AlarmReceiver] after a scheduled notification was posted. */
		@JvmStatic
		fun onNotificationFired(id: Int, key: String) {
			val plugin = live ?: return
			try {
				plugin.emitSignal(SIGNAL_NOTIFICATION_DELIVERED, id, key)
			} catch (e: Exception) {
				Log.w(TAG, "delivery signal refused: ${e.message}")
			}
		}
	}

	// Context, not activity: the power and notification services have nothing to do
	// with the window, and a Godot host that is a fragment rather than an activity
	// still has a context.
	private val powerManager: PowerManager?
		get() = (context ?: activity)?.getSystemService(Context.POWER_SERVICE) as? PowerManager

	private val notificationManager: NotificationManager?
		get() = (context ?: activity)
			?.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

	private val center: NotificationCenter?
		get() = (context ?: activity)?.let { NotificationCenter(it.applicationContext) }

	/** Read once — the boot id cannot change without the process dying with it. */
	private val cachedBootId: String by lazy { readBootId() }

	private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

	/** Set when the app was launched (or resumed) from a notification tap. */
	private var launchPayload: String = ""

	/** Whatever the launching Intent carried as dev arguments (doc 13 D-20). */
	@Volatile
	private var launchArgs: List<String> = emptyList()

	/**
	 * The Vulkan surface Godot presents to, handed to every plugin by
	 * [onVkSurfaceCreated]. It is the surface a frame-rate vote has to be cast on
	 * — the vote is a property of the SURFACE, not of the process, so a surface
	 * that was recreated (the Fold folding, a rotation, a resume) has no vote
	 * until it is cast again. That is what [pinnedFps] is kept for.
	 */
	@Volatile
	private var vkSurface: Surface? = null

	/**
	 * The last rate GDScript asked for, or `< 0` for "never asked". Re-applied on
	 * every new surface. Not a policy — a policy would decide the number; this
	 * only remembers the one it was given.
	 */
	@Volatile
	private var pinnedFps: Double = -1.0

	@Volatile
	private var pinnedFixed: Boolean = true

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo(SIGNAL_THERMAL_STATUS_CHANGED, Integer::class.java),
		SignalInfo(SIGNAL_PERMISSION_RESULT, java.lang.Boolean::class.java),
		SignalInfo(SIGNAL_NOTIFICATION_DELIVERED, Integer::class.java, String::class.java),
		SignalInfo(SIGNAL_NOTIFICATION_OPENED, String::class.java),
	)

	override fun onGodotSetupCompleted() {
		super.onGodotSetupCompleted()
		live = this
		registerThermalListener()
		captureLaunchPayload()
		captureLaunchArgs()
	}

	override fun onMainResume() {
		super.onMainResume()
		// A tap while the process is alive arrives as a new intent on the launcher
		// activity; re-reading it here is the only hook a GodotPlugin is given.
		captureLaunchPayload()
		captureLaunchArgs()
	}

	override fun onMainDestroy() {
		unregisterThermalListener()
		vkSurface = null
		live = null
		super.onMainDestroy()
	}

	// A frame-rate vote lives on the Surface and dies with it, so both callbacks
	// re-cast whatever GDScript last asked for. `onVkSurfaceChanged` fires on the
	// Fold's fold/unfold as well as on rotation, which is precisely the moment the
	// pin would otherwise be silently lost.
	override fun onVkSurfaceCreated(surface: Surface) {
		super.onVkSurfaceCreated(surface)
		vkSurface = surface
		reapplyFrameRate()
	}

	override fun onVkSurfaceChanged(surface: Surface, width: Int, height: Int) {
		super.onVkSurfaceChanged(surface, width, height)
		vkSurface = surface
		reapplyFrameRate()
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

	// ---------------------------------------------------------- launch args

	/**
	 * The dev/QA arguments the launching Intent carried, **verbatim** — including
	 * the literal `--` separator if the caller supplied one. `game/dev_args.gd`
	 * merges this with `OS.get_cmdline_user_args()` and applies Godot's own
	 * "everything after `--`" convention; deciding what an argument means is not
	 * this file's business.
	 *
	 * Two extras are read, in this order, and both are appended:
	 *
	 *  * `command_line_params` — a string ARRAY, which is what
	 *    `adb shell am start … --esa command_line_params "--,--resume,--zoom=1.0"`
	 *    produces and what Godot's launcher is documented to consume. On this
	 *    export template it never reaches `OS.get_cmdline_user_args()` (doc 13
	 *    D-20), which is the whole reason this method exists;
	 *  * `args` — a single string, split on whitespace, for
	 *    `--es args "--resume --zoom=1.0"`. The comma-separated array form is the
	 *    one every session has got wrong at least once; this one has no syntax to
	 *    get wrong.
	 *
	 * Non-consuming and idempotent: `game/main.gd` asks more than once, and a
	 * dev argument is not a deep link — replaying `--zoom=1.0` after a rotation is
	 * the *correct* answer, where replaying a three-day-old incident is not.
	 * Returns an empty array on a plain player launch, which is every launch that
	 * did not come from `adb`.
	 */
	@UsedByGodot
	fun launch_args(): Array<String> {
		if (launchArgs.isEmpty()) {
			captureLaunchArgs()
		}
		return launchArgs.toTypedArray()
	}

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

	// ------------------------------------------------------------ refresh rate

	/**
	 * DECLARE the frame rate this app intends to present at (doc 13 §2.8,
	 * report 98 RR-126). Returns true when the surface vote was actually cast.
	 *
	 * **The fault this closes.** The game caps `Engine.max_fps` at the preset's
	 * `target_fps` and has never told the display about it. On a fixed 60 Hz panel
	 * that costs nothing. On the reference device — a Galaxy Z Fold 6 whose inner
	 * panel is a 1–120 Hz LTPO — the platform is left to INFER a mode from
	 * observed present cadence, so the panel hunts whenever the cadence changes,
	 * and a mode change mid-scan is the horizontal band the player reports.
	 *
	 * Two votes are cast, because they answer two different questions and Android
	 * has no one call that answers both:
	 *
	 *  * **`Surface.setFrameRate(fps, compatibility)`** (API 30) tells
	 *    SurfaceFlinger what the app PRODUCES. `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE`
	 *    is the honest compatibility for content that has capped itself: it says
	 *    "this rate is fixed, pick a mode that carries it cleanly", where
	 *    `_DEFAULT` says only "I would prefer this" and leaves the heuristics in
	 *    charge. The **two-argument** overload is deliberate: on API 31+ it means
	 *    `CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS`, so a mode switch the panel could
	 *    not make invisibly is REFUSED rather than made — this call may not become
	 *    a new source of the artifact it exists to remove.
	 *  * **`window.attributes.preferredRefreshRate` / `preferredDisplayModeId`**
	 *    tell the window manager which MODE to sit in. `preferredRefreshRate` is
	 *    a request the framework matches loosely (nearest); `preferredDisplayModeId`
	 *    names one exactly, and is set **only for a mode at the current
	 *    resolution**, because a mode that also changes resolution is a
	 *    reconfiguration, not a refresh-rate switch, and is the one kind the
	 *    platform cannot do seamlessly.
	 *
	 * `fps <= 0` CLEARS both votes — that is how the app hands the panel back to
	 * the platform's own policy, and it is what `--refresh=off` leaves in place.
	 *
	 * API 30 is the floor for the surface vote and `minSdk` is 29, so an API-29
	 * device takes the documented fallback: **no vote at all, today's behaviour
	 * exactly**, reported as `false` rather than pretended.
	 */
	@UsedByGodot
	fun set_frame_rate(fps: Double, fixed: Boolean): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			// Recorded as "never declared", not as "declared and ignored":
			// `current_frame_rate_pin()` is a diagnostic and it may only report
			// what the platform was actually told.
			Log.i(TAG, "frame rate not declared: API ${Build.VERSION.SDK_INT} < 30")
			return false
		}
		pinnedFps = fps
		pinnedFixed = fixed
		val cast = castSurfaceFrameRate(fps, fixed)
		applyPreferredMode(fps)
		return cast
	}

	/**
	 * The panel's refresh rates at the CURRENT resolution, rounded to whole Hz,
	 * de-duplicated and ascending; empty when there is no display to ask.
	 *
	 * Rounded because the consumer is a settings row and a mode chooser that
	 * reasons in integer multiples, and because every rate a phone panel actually
	 * publishes is a whole number (60 / 90 / 120 / 144, and the LTPO rungs below
	 * them). The rounding is this method's alone: [set_frame_rate] matches modes
	 * on the unrounded `Display.Mode.refreshRate`, so the pin itself loses nothing.
	 */
	@UsedByGodot
	fun get_supported_refresh_rates(): IntArray {
		val display = currentDisplay() ?: return IntArray(0)
		val current = display.mode ?: return IntArray(0)
		val rates = sortedSetOf<Int>()
		for (mode in display.supportedModes ?: emptyArray()) {
			if (mode.physicalWidth != current.physicalWidth ||
				mode.physicalHeight != current.physicalHeight
			) {
				continue
			}
			val hz = mode.refreshRate.roundToInt()
			if (hz > 0) {
				rates.add(hz)
			}
		}
		return rates.toIntArray()
	}

	/**
	 * The rate the app is presently declaring, rounded to whole Hz, or `-1` when
	 * it has never declared one. GDScript's `RefreshPin` keeps its own copy for
	 * the idempotence test; this one exists so a device session can read the
	 * PLUGIN's answer rather than the shell's belief about it — and, because its
	 * own signature carries no `double`, it answers `-1` rather than going missing
	 * if [set_frame_rate] were ever to fail registration.
	 */
	@UsedByGodot
	fun current_frame_rate_pin(): Int = if (pinnedFps < 0.0) -1 else pinnedFps.roundToInt()

	private fun castSurfaceFrameRate(fps: Double, fixed: Boolean): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return false
		}
		val surface = currentSurface() ?: return false
		if (!surface.isValid) {
			return false
		}
		return try {
			surface.setFrameRate(
				fps.toFloat().coerceAtLeast(0.0f),
				if (fps > 0.0 && fixed) {
					Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE
				} else {
					Surface.FRAME_RATE_COMPATIBILITY_DEFAULT
				},
			)
			true
		} catch (e: Exception) {
			Log.w(TAG, "setFrameRate refused: ${e.message}")
			false
		}
	}

	/**
	 * `Window` is UI-thread-only, hence the hop — the same one
	 * [set_sustained_performance] takes.
	 */
	private fun applyPreferredMode(fps: Double) {
		val host = activity ?: return
		val chosen = if (fps > 0.0) modeFor(fps) else null
		runOnHostThread {
			try {
				val params = host.window.attributes
				params.preferredRefreshRate = chosen?.refreshRate ?: 0.0f
				params.preferredDisplayModeId = chosen?.modeId ?: 0
				host.window.attributes = params
				Log.i(TAG, "refresh pin: fps=$fps mode=${chosen?.refreshRate ?: 0.0f}Hz")
			} catch (e: Exception) {
				Log.w(TAG, "preferred display mode refused: ${e.message}")
			}
		}
	}

	/**
	 * **Mirror of `RefreshPin.choose_refresh_hz()` in `game/render/refresh_pin.gd`,
	 * which is where the rule is written down and table-tested.** It is duplicated
	 * here for the same reason `PerfGovernor` mirrors `THERMAL_STATUS_*`: the rule
	 * has to run on a `Display.Mode` object that only exists on a device, and the
	 * suite has to be able to check the rule without one.
	 *
	 * Three clauses, in order, over the modes at the current resolution:
	 *
	 *  1. **the SMALLEST mode that is an integer multiple of the target** — 60 on
	 *     a {60, 120} panel for a 60 fps cap, 90 on a {60, 90, 120} panel for 45.
	 *     A multiple is what makes the cadence exact: every app frame is held for
	 *     the same whole number of scanouts, which is the condition under which a
	 *     capped game has no beat against the panel at all. Smallest rather than
	 *     largest because every extra scanout is battery for a picture that does
	 *     not change — 120 Hz for a 60 fps game buys nothing and doc 13 §2.8 calls
	 *     capping at 60 "the single biggest battery lever available".
	 *  2. **no multiple exists: the FASTEST mode at or above the target** — 120 for
	 *     a 45 fps cap on a {60, 120} panel. Neither 60 nor 120 divides 45, so
	 *     some frames are held one scanout longer than others whatever is picked;
	 *     the jitter is one scanout, so the faster mode halves it (±4.2 ms at
	 *     120 Hz against ±8.3 ms at 60).
	 *  3. **nothing reaches the target: the fastest mode there is** — the panel
	 *     cannot do what the preset asked, and saying so beats asking for a mode
	 *     that does not exist.
	 *
	 * `null` when there is no display or no mode at this resolution: the surface
	 * vote is still cast and the window is left alone, which is strictly more than
	 * the app did before and strictly less than a guess.
	 */
	private fun modeFor(fps: Double): Display.Mode? {
		val display = currentDisplay() ?: return null
		val current = display.mode ?: return null
		val candidates = (display.supportedModes ?: emptyArray()).filter {
			it.physicalWidth == current.physicalWidth &&
				it.physicalHeight == current.physicalHeight &&
				it.refreshRate > 0.0f
		}
		if (candidates.isEmpty()) {
			return null
		}
		var best: Display.Mode? = null
		var bestRate = 0.0f
		for (mode in candidates) {
			val rate = mode.refreshRate
			if (rate + RATE_EPSILON_HZ < fps) {
				continue
			}
			val multiple = (rate / fps).roundToInt()
			if (multiple < 1 || abs(rate - multiple * fps) > RATE_EPSILON_HZ) {
				continue
			}
			if (best == null || rate < bestRate) {
				best = mode
				bestRate = rate
			}
		}
		if (best != null) {
			return best
		}
		for (mode in candidates) {
			if (mode.refreshRate + RATE_EPSILON_HZ < fps) {
				continue
			}
			if (best == null || mode.refreshRate > bestRate) {
				best = mode
				bestRate = mode.refreshRate
			}
		}
		if (best != null) {
			return best
		}
		for (mode in candidates) {
			if (best == null || mode.refreshRate > bestRate) {
				best = mode
				bestRate = mode.refreshRate
			}
		}
		return best
	}

	/**
	 * The surface Godot presents to. The Vulkan callback is the first source
	 * because it is handed the exact surface the renderer uses; the render view is
	 * the fallback for a host that never delivered the callback (a GL build, or a
	 * plugin attached after the surface existed).
	 */
	private fun currentSurface(): Surface? {
		vkSurface?.let { return it }
		return try {
			getGodot().renderView?.view?.holder?.surface
		} catch (e: Exception) {
			Log.w(TAG, "render view surface unreadable: ${e.message}")
			null
		}
	}

	private fun currentDisplay(): Display? {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return null
		}
		return try {
			(context ?: activity)?.display
		} catch (e: Exception) {
			Log.w(TAG, "display unreadable: ${e.message}")
			null
		}
	}

	/** Re-cast the standing vote on a surface that has just been (re)created. */
	private fun reapplyFrameRate() {
		val fps = pinnedFps
		if (fps < 0.0 || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return
		}
		castSurfaceFrameRate(fps, pinnedFixed)
	}

	// ------------------------------------------------------------- permissions

	/**
	 * The only question that matters before scheduling anything: will the system
	 * show what we post? Covers the runtime permission *and* the per-app master
	 * switch in system settings, which exists on every API level and which no
	 * permission state reports.
	 */
	@UsedByGodot
	fun notifications_enabled(): Boolean = notificationManager?.areNotificationsEnabled() ?: false

	/**
	 * `granted` | `denied` | `denied_permanent` | `never_asked` | `unsupported`.
	 *
	 * `denied_permanent` is inferred the only way Android allows: the permission is
	 * not held, we have asked at least once, and the system now declines to show a
	 * rationale — which is its way of saying the dialog will never appear again.
	 * Getting this wrong in the optimistic direction produces an app that prompts
	 * forever and never shows a dialog, so the pessimistic reading is the safe one.
	 */
	@UsedByGodot
	fun permission_state(): String {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
			// No runtime permission exists below 33; the master switch still does,
			// so `notifications_enabled()` stays the truthful reading there.
			return if (notifications_enabled()) STATE_GRANTED else STATE_UNSUPPORTED
		}
		val host = activity ?: return STATE_UNSUPPORTED
		if (host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
			PackageManager.PERMISSION_GRANTED
		) {
			return STATE_GRANTED
		}
		if (!hasAsked()) {
			return STATE_NEVER_ASKED
		}
		return if (host.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))
			STATE_DENIED else STATE_DENIED_PERMANENT
	}

	/**
	 * Show the system dialog. The answer arrives as `permission_result(granted)`;
	 * a call that cannot possibly produce a dialog (below API 33, or already
	 * decided) answers immediately rather than leaving GDScript waiting on a signal
	 * that will never come.
	 */
	@UsedByGodot
	fun request_notification_permission() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
			emitPermissionResult(notifications_enabled())
			return
		}
		val host = activity ?: run {
			emitPermissionResult(false)
			return
		}
		if (host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
			PackageManager.PERMISSION_GRANTED
		) {
			emitPermissionResult(true)
			return
		}
		markAsked()
		runOnHostThread {
			try {
				host.requestPermissions(
					arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
			} catch (e: Exception) {
				Log.w(TAG, "permission request refused: ${e.message}")
				emitPermissionResult(false)
			}
		}
	}

	override fun onMainRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>?,
		grantResults: IntArray?,
	) {
		super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode != PERMISSION_REQUEST_CODE) {
			return
		}
		val granted = grantResults != null && grantResults.isNotEmpty() &&
			grantResults[0] == PackageManager.PERMISSION_GRANTED
		emitPermissionResult(granted)
	}

	/**
	 * The escape hatch for `denied_permanent`: the app can never prompt again, but
	 * it can still take the player to the screen where the switch lives. Falls back
	 * to the app details page on hosts that do not implement the notification one.
	 */
	@UsedByGodot
	fun open_app_notification_settings(): Boolean {
		val host = activity ?: return false
		val direct = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
			.putExtra(Settings.EXTRA_APP_PACKAGE, host.packageName)
			.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
			.setData(Uri.fromParts("package", host.packageName, null))
			.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		return startFirstResolvable(host, direct, fallback)
	}

	private fun startFirstResolvable(host: Activity, vararg intents: Intent): Boolean {
		for (intent in intents) {
			try {
				host.startActivity(intent)
				return true
			} catch (e: Exception) {
				Log.w(TAG, "settings intent refused: ${e.message}")
			}
		}
		return false
	}

	// ----------------------------------------------------------- notifications

	/**
	 * Create one Android channel per enabled class (doc 13 §2.5). Called once at
	 * bring-up from GDScript, with the ids and importances out of
	 * `data/notifications.json` — this side invents neither.
	 */
	@UsedByGodot
	fun ensure_channel(
		channel_id: String,
		name: String,
		importance: String,
		sound: Boolean,
		vibrate: Boolean,
	): Boolean = center?.ensureChannel(channel_id, name, importance, sound, vibrate) ?: false

	/** True once [ensure_channel] has created it (and the player has not deleted it). */
	@UsedByGodot
	fun channel_exists(channel_id: String): Boolean = center?.channelExists(channel_id) ?: false

	/**
	 * Post now. `priority` names the channel-ish urgency for callers that have no
	 * channel id to hand (`critical` | `important` | `routine`); a caller that does
	 * have one should pass it as `priority` directly, because an unrecognised value
	 * is used verbatim as the channel id.
	 */
	@UsedByGodot
	fun show_notification(id: Int, title: String, body: String, priority: String): Boolean {
		val entry = NotificationCenter.Entry(
			id = id, atMs = 0L, channel = channelFor(priority),
			title = title, body = body, payload = "", key = "")
		return center?.postNow(entry) ?: false
	}

	/**
	 * Schedule for `at_unix` (**seconds**, the unit every clock in this game speaks).
	 * A time already past posts immediately rather than being dropped: a plan built
	 * during the pause sequence can name a moment that arrives before the JNI hop
	 * lands, and silently discarding it would be a lost notification with no trace.
	 */
	@UsedByGodot
	fun schedule_notification(
		id: Int,
		title: String,
		body: String,
		at_unix: Long,
		priority: String,
	): Boolean {
		val entry = NotificationCenter.Entry(
			id = id, atMs = at_unix * 1000L, channel = channelFor(priority),
			title = title, body = body, payload = "", key = "")
		return center?.schedule(entry, System.currentTimeMillis()) ?: false
	}

	/**
	 * The dictionary form `game/notifications/native_notification_sink.gd` uses:
	 * one decided plan, rendered. `fire_at_wall_ms` in the future is an alarm;
	 * absent or past is a post. Keys: `id`, `channel_id`, `title`, `body`,
	 * `deeplink`, `key`, `fire_at_wall_ms`.
	 */
	@UsedByGodot
	fun post_notification(plan: Dictionary): Boolean {
		val bridge = center ?: return false
		val id = intOf(plan["id"], 0)
		if (id == 0) {
			return false
		}
		val entry = NotificationCenter.Entry(
			id = id,
			atMs = longOf(plan["fire_at_wall_ms"], 0L),
			channel = stringOf(plan["channel_id"]),
			title = stringOf(plan["title"]),
			body = stringOf(plan["body"]),
			payload = stringOf(plan["deeplink"]),
			key = stringOf(plan["key"]),
		)
		val now = System.currentTimeMillis()
		return if (entry.atMs > now + 1000L) bridge.schedule(entry, now) else bridge.postNow(entry)
	}

	@UsedByGodot
	fun cancel_notification(id: Int): Boolean = center?.cancel(id) ?: false

	/** Everything pending, dropped. Returns how many alarms were cancelled. */
	@UsedByGodot
	fun cancel_notifications(): Int = center?.cancelAll() ?: 0

	@UsedByGodot
	fun scheduled_ids(): IntArray = center?.scheduledIds() ?: IntArray(0)

	/**
	 * The deeplink of the notification the app was opened from, or `""`. Consuming
	 * clears it — a payload that survived would deep-link the player back into a
	 * three-day-old incident every launch.
	 */
	@UsedByGodot
	fun consume_launch_payload(): String {
		val payload = launchPayload
		launchPayload = ""
		return payload
	}

	// ---------------------------------------------------------------- internals

	/**
	 * The channel-id mapping doc 13 §2.5 fixes. Anything unrecognised is passed
	 * through untouched, so GDScript can hand a real channel id from
	 * `data/notifications.json` and skip the shorthand entirely.
	 */
	private fun channelFor(priority: String): String = when (priority.lowercase()) {
		"critical", "p1", "p1_critical", "high" -> "slacum_critical"
		"important", "p2", "p2_important", "default" -> "slacum_important"
		"routine", "p3", "p3_routine", "low" -> "slacum_routine"
		"", "ambient", "p4", "p4_ambient", "min" -> "slacum_routine"
		else -> priority
	}

	private fun captureLaunchPayload() {
		val intent = activity?.intent ?: return
		val payload = intent.getStringExtra(NotificationCenter.EXTRA_PAYLOAD) ?: return
		if (payload.isEmpty()) {
			return
		}
		// Consume it off the intent as well: `activity.intent` is sticky, so a
		// plain rotation would otherwise replay the same deep link.
		intent.removeExtra(NotificationCenter.EXTRA_PAYLOAD)
		launchPayload = payload
		try {
			emitSignal(SIGNAL_NOTIFICATION_OPENED, payload)
		} catch (e: Exception) {
			Log.w(TAG, "open signal refused: ${e.message}")
		}
	}

	/**
	 * Reads both argument extras off the current Intent. Unlike
	 * [captureLaunchPayload] this does **not** strip them: the Intent is sticky,
	 * and a sticky dev argument is a feature — the same `am start` line has to
	 * survive a rotation and a `launch_args()` call from more than one place in
	 * `game/main.gd`. An Intent carrying nothing leaves the previous answer alone,
	 * so a resume cannot erase the arguments the launch arrived with.
	 */
	private fun captureLaunchArgs() {
		val intent = activity?.intent ?: return
		val collected = ArrayList<String>()
		try {
			intent.getStringArrayExtra(EXTRA_COMMAND_LINE)?.forEach { value ->
				if (value != null && value.isNotEmpty()) {
					collected.add(value)
				}
			}
			intent.getStringExtra(EXTRA_ARGS)?.split(' ', '\t', '\n')?.forEach { value ->
				val trimmed = value.trim()
				if (trimmed.isNotEmpty()) {
					collected.add(trimmed)
				}
			}
		} catch (e: Exception) {
			// A malformed extra from `adb` must not take the launch down with it.
			Log.w(TAG, "launch args unreadable: ${e.message}")
			return
		}
		if (collected.isEmpty()) {
			return
		}
		launchArgs = collected
		Log.i(TAG, "launch args: $collected")
	}

	private fun emitPermissionResult(granted: Boolean) {
		try {
			emitSignal(SIGNAL_PERMISSION_RESULT, granted)
		} catch (e: Exception) {
			Log.w(TAG, "permission signal refused: ${e.message}")
		}
	}

	private fun hasAsked(): Boolean = (context ?: activity)
		?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		?.getBoolean(PREF_ASKED, false) ?: false

	private fun markAsked() {
		(context ?: activity)
			?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
			?.edit()?.putBoolean(PREF_ASKED, true)?.apply()
	}

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

	// Godot marshals every Variant number as Integer/Long/Double depending on the
	// value, so a dictionary field has to be read through Number rather than cast.
	private fun stringOf(value: Any?): String = value?.toString() ?: ""

	private fun intOf(value: Any?, fallback: Int): Int =
		(value as? Number)?.toInt() ?: fallback

	private fun longOf(value: Any?, fallback: Long): Long =
		(value as? Number)?.toLong() ?: fallback
}
