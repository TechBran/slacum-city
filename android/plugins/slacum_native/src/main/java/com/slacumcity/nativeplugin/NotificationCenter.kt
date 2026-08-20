package com.slacumcity.nativeplugin

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The notification platform half of doc 13 (§2.5, §2.6) — channels, `AlarmManager`
 * and the reboot-replay registry. **No policy lives here.** Rate limiting, quiet
 * hours, coalescing and class assignment are doc 08's and have already run in
 * GDScript by the time anything reaches this file (report C-71); what arrives is
 * a final decision with a channel, a fire time and two rendered sentences.
 *
 * Three facts shape every choice below:
 *
 *  1. **The app is not running when these fire.** So an entry has to survive in a
 *     form the OS can act on alone: an `AlarmManager` alarm plus a row in
 *     `filesDir/notif_schedule.json`, because alarms are dropped on reboot and
 *     nothing else would know to re-arm them.
 *  2. **Alarms are inexact, by choice.** `setAndAllowWhileIdle` is the strongest
 *     delivery a game may honestly ask for: `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`
 *     are Play-restricted to clocks and calendars, and requesting one risks the
 *     listing. Doze can therefore slip a fire by ~15 minutes, which is exactly why
 *     GDScript drops anything whose lead is under `doze_slop_s + min_useful_lead_s`
 *     and why the copy never states a wall-clock time.
 *  3. **Ids are assigned by the caller and reused per batch.** `cancelAll()` runs
 *     before every plan, so an id only has to be unique inside one batch — which
 *     makes the persisted registry trivially replaceable and kills the whole class
 *     of stale-alarm bugs.
 */
internal class NotificationCenter(private val context: Context) {

	companion object {
		private const val TAG = "SlacumNative"

		/** Rewritten on every schedule/cancel; read by [BootReceiver]. */
		const val SCHEDULE_FILE = "notif_schedule.json"

		const val EXTRA_ID = "slacum_id"
		const val EXTRA_CHANNEL = "slacum_channel"
		const val EXTRA_TITLE = "slacum_title"
		const val EXTRA_BODY = "slacum_body"
		const val EXTRA_PAYLOAD = "slacum_payload"
		const val EXTRA_KEY = "slacum_key"

		const val ACTION_FIRE = "com.slacumcity.nativeplugin.FIRE"

		/** Channel importance names, as GDScript spells them in data/notifications.json. */
		fun importanceOf(name: String): Int = when (name.lowercase()) {
			"high" -> NotificationManager.IMPORTANCE_HIGH
			"default" -> NotificationManager.IMPORTANCE_DEFAULT
			"low" -> NotificationManager.IMPORTANCE_LOW
			"min" -> NotificationManager.IMPORTANCE_MIN
			else -> NotificationManager.IMPORTANCE_DEFAULT
		}
	}

	/** One scheduled or posted notification, in the only shape that has to persist. */
	data class Entry(
		val id: Int,
		val atMs: Long,
		val channel: String,
		val title: String,
		val body: String,
		val payload: String,
		val key: String,
	) {
		fun toJson(): JSONObject = JSONObject()
			.put("id", id)
			.put("at_ms", atMs)
			.put("channel", channel)
			.put("title", title)
			.put("body", body)
			.put("payload", payload)
			.put("key", key)

		companion object {
			fun fromJson(o: JSONObject): Entry = Entry(
				id = o.optInt("id", 0),
				atMs = o.optLong("at_ms", 0L),
				channel = o.optString("channel", ""),
				title = o.optString("title", ""),
				body = o.optString("body", ""),
				payload = o.optString("payload", ""),
				key = o.optString("key", ""),
			)

			fun fromIntent(intent: Intent): Entry = Entry(
				id = intent.getIntExtra(EXTRA_ID, 0),
				atMs = 0L,
				channel = intent.getStringExtra(EXTRA_CHANNEL) ?: "",
				title = intent.getStringExtra(EXTRA_TITLE) ?: "",
				body = intent.getStringExtra(EXTRA_BODY) ?: "",
				payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: "",
				key = intent.getStringExtra(EXTRA_KEY) ?: "",
			)
		}
	}

	private val notificationManager: NotificationManager?
		get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

	private val alarmManager: AlarmManager?
		get() = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager

	// ------------------------------------------------------------------ channels

	/**
	 * Create one channel, once. Android owns a channel after creation — importance,
	 * sound and vibration become the *player's* settings and a re-create cannot take
	 * them back — so this is deliberately create-if-absent and never update: a game
	 * that quietly restored its own sound preference every launch would be lying
	 * about the switch in system settings (spec §49).
	 */
	fun ensureChannel(
		channelId: String,
		name: String,
		importance: String,
		sound: Boolean,
		vibrate: Boolean,
	): Boolean {
		if (channelId.isEmpty()) {
			return false
		}
		val manager = notificationManager ?: return false
		if (manager.getNotificationChannel(channelId) != null) {
			return true
		}
		return try {
			val channel = NotificationChannel(channelId, name.ifEmpty { channelId },
				importanceOf(importance))
			channel.enableVibration(vibrate)
			if (sound) {
				val uri: Uri? = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
				val attrs = AudioAttributes.Builder()
					.setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
					.setUsage(AudioAttributes.USAGE_NOTIFICATION)
					.build()
				channel.setSound(uri, attrs)
			} else {
				channel.setSound(null, null)
			}
			manager.createNotificationChannel(channel)
			true
		} catch (e: Exception) {
			Log.w(TAG, "channel $channelId refused: ${e.message}")
			false
		}
	}

	fun channelExists(channelId: String): Boolean =
		notificationManager?.getNotificationChannel(channelId) != null

	// ------------------------------------------------------------------- posting

	/** Post right now. Returns false when the platform refused it (or is missing). */
	fun postNow(entry: Entry): Boolean {
		val manager = notificationManager ?: return false
		val channelId = entry.channel.ifEmpty { return false }
		if (manager.getNotificationChannel(channelId) == null) {
			// A channel that does not exist silently swallows the notification on
			// API 26+, so refuse loudly instead of pretending it went out.
			Log.w(TAG, "no channel $channelId — dropping notification ${entry.id}")
			return false
		}
		return try {
			manager.notify(entry.id, build(entry, channelId))
			true
		} catch (e: Exception) {
			Log.w(TAG, "notify ${entry.id} refused: ${e.message}")
			false
		}
	}

	private fun build(entry: Entry, channelId: String): Notification {
		val builder = Notification.Builder(context, channelId)
			.setSmallIcon(context.applicationInfo.icon)
			.setContentTitle(entry.title)
			.setContentText(entry.body)
			.setStyle(Notification.BigTextStyle().bigText(entry.body))
			.setAutoCancel(true)
			.setShowWhen(true)
		val launch = launchIntent(entry)
		if (launch != null) {
			builder.setContentIntent(launch)
		}
		return builder.build()
	}

	/**
	 * Tap → the game's own launcher activity, with the deeplink payload attached.
	 * Resolved through the package manager rather than naming `GodotApp`: the host
	 * activity class is the *template's* business, and a plugin that hardcoded it
	 * would break the day the template renames it.
	 */
	private fun launchIntent(entry: Entry): PendingIntent? {
		val intent = context.packageManager
			.getLaunchIntentForPackage(context.packageName) ?: return null
		intent.putExtra(EXTRA_PAYLOAD, entry.payload)
		intent.putExtra(EXTRA_KEY, entry.key)
		intent.putExtra(EXTRA_ID, entry.id)
		intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
		return PendingIntent.getActivity(
			context, entry.id, intent,
			PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
		)
	}

	// ----------------------------------------------------------------- scheduling

	/**
	 * Arm one alarm and record it. `atMs` in the past (or within a second of now)
	 * posts immediately instead — a plan built at pause time can legitimately name a
	 * moment that has already arrived by the time the JNI hop lands.
	 */
	fun schedule(entry: Entry, nowMs: Long): Boolean {
		if (entry.atMs <= nowMs + 1000L) {
			return postNow(entry)
		}
		val alarms = alarmManager ?: return false
		return try {
			alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, entry.atMs, alarmIntent(entry))
			addToStore(entry)
			true
		} catch (e: Exception) {
			Log.w(TAG, "alarm ${entry.id} refused: ${e.message}")
			false
		}
	}

	fun cancel(id: Int): Boolean {
		val entries = readStore()
		val stored = entries.firstOrNull { it.id == id }
		// The alarm is cancelled through an equal PendingIntent, and equality is
		// action + data + component — never extras — so a synthesised stand-in with
		// the right id cancels just as well as the stored row.
		alarmManager?.cancel(alarmIntent(stored ?: Entry(id, 0L, "", "", "", "", "")))
		notificationManager?.cancel(id)
		val remaining = entries.filter { it.id != id }
		writeStore(remaining)
		return remaining.size != entries.size
	}

	/** Everything pending, dropped — doc 08 §2.13's resume step. Returns the count. */
	fun cancelAll(): Int {
		val entries = readStore()
		val alarms = alarmManager
		for (entry in entries) {
			alarms?.cancel(alarmIntent(entry))
		}
		writeStore(emptyList())
		return entries.size
	}

	fun scheduledIds(): IntArray = readStore().map { it.id }.toIntArray()

	private fun alarmIntent(entry: Entry): PendingIntent {
		val intent = Intent(context, AlarmReceiver::class.java).apply {
			action = ACTION_FIRE
			// The id is in the data URI as well as in the extras: PendingIntent
			// equality ignores extras entirely, so two alarms differing only by
			// extras would collapse into one and the second would overwrite the
			// first. This is the single most common AlarmManager bug there is.
			data = Uri.parse("slacum://notification/${entry.id}")
			putExtra(EXTRA_ID, entry.id)
			putExtra(EXTRA_CHANNEL, entry.channel)
			putExtra(EXTRA_TITLE, entry.title)
			putExtra(EXTRA_BODY, entry.body)
			putExtra(EXTRA_PAYLOAD, entry.payload)
			putExtra(EXTRA_KEY, entry.key)
		}
		return PendingIntent.getBroadcast(
			context, entry.id, intent,
			PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
		)
	}

	// ---------------------------------------------------------------- reboot replay

	/**
	 * Re-arm everything still in the future and forget the rest. Called from
	 * [BootReceiver]: Android drops every alarm on reboot, and a player who reboots
	 * their phone overnight would otherwise silently lose every notification the
	 * last session scheduled.
	 *
	 * A user-initiated force-stop also clears alarms and, by platform design,
	 * **cannot** be recovered from until the app is launched again. That is accepted
	 * and documented (doc 13 §2.6) rather than worked around.
	 */
	fun replayAfterBoot(nowMs: Long): Int {
		val alive = readStore().filter { it.atMs > nowMs }
		val alarms = alarmManager ?: return 0
		var armed = 0
		for (entry in alive) {
			try {
				alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, entry.atMs, alarmIntent(entry))
				armed += 1
			} catch (e: Exception) {
				Log.w(TAG, "replay ${entry.id} refused: ${e.message}")
			}
		}
		writeStore(alive)
		return armed
	}

	// ---------------------------------------------------------------------- store

	private fun storeFile(): File = File(context.filesDir, SCHEDULE_FILE)

	fun readStore(): List<Entry> {
		val file = storeFile()
		if (!file.exists()) {
			return emptyList()
		}
		return try {
			val root = JSONObject(file.readText())
			val array: JSONArray = root.optJSONArray("entries") ?: return emptyList()
			(0 until array.length()).mapNotNull { i ->
				array.optJSONObject(i)?.let { Entry.fromJson(it) }
			}
		} catch (e: Exception) {
			Log.w(TAG, "schedule store unreadable: ${e.message}")
			emptyList()
		}
	}

	private fun writeStore(entries: List<Entry>) {
		try {
			val array = JSONArray()
			// Sorted by fire time then id: the file is diffed by hand during
			// bring-up and a stable order is worth the two comparisons.
			for (entry in entries.sortedWith(compareBy({ it.atMs }, { it.id }))) {
				array.put(entry.toJson())
			}
			val root = JSONObject().put("version", 1).put("entries", array)
			storeFile().writeText(root.toString())
		} catch (e: Exception) {
			Log.w(TAG, "schedule store unwritable: ${e.message}")
		}
	}

	private fun addToStore(entry: Entry) {
		val entries = readStore().filter { it.id != entry.id } + entry
		writeStore(entries)
	}

	/** Drop one row after it fired, without touching its (already spent) alarm. */
	fun forget(id: Int) {
		writeStore(readStore().filter { it.id != id })
	}
}
