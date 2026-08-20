package com.slacumcity.nativeplugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Where a scheduled notification actually becomes visible (doc 13 §2.6).
 *
 * This runs with the game process dead — that is the entire point of the feature —
 * so it may do nothing but read its own extras and post. No sim, no policy, no
 * file the game owns: the plan was decided in GDScript before the app went away
 * and every question it could have asked has already been answered.
 *
 * When the process *is* alive, [SlacumNative.onNotificationFired] gets told so the
 * shell can log a delivery receipt (doc 13 §3.2 `delivered_log`) for the WHILE YOU
 * WERE AWAY report's reconciliation lines. That path is a bonus, never a
 * requirement: the notification is posted before the plugin is consulted.
 */
class AlarmReceiver : BroadcastReceiver() {

	companion object {
		private const val TAG = "SlacumNative"
	}

	override fun onReceive(context: Context, intent: Intent) {
		if (intent.action != NotificationCenter.ACTION_FIRE) {
			return
		}
		val entry = NotificationCenter.Entry.fromIntent(intent)
		if (entry.id == 0) {
			return
		}
		try {
			val center = NotificationCenter(context.applicationContext)
			center.postNow(entry)
			// The alarm is spent; the registry must forget it or a reboot would
			// re-arm a notification the player has already seen.
			center.forget(entry.id)
		} catch (e: Exception) {
			Log.w(TAG, "alarm ${entry.id} failed to post: ${e.message}")
		}
		SlacumNative.onNotificationFired(entry.id, entry.key)
	}
}
