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
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File

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
		live = null
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
