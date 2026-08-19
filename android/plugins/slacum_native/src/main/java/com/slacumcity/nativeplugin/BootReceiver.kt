package com.slacumcity.nativeplugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms the schedule after a reboot (doc 13 §2.6).
 *
 * Android drops every `AlarmManager` alarm when the device restarts, and the game
 * is not running to notice. Without this receiver a player who reboots overnight
 * loses every notification the last session planned — silently, which is the worst
 * kind of loss because nothing in the app can detect it either.
 *
 * `RECEIVE_BOOT_COMPLETED` is a normal permission (no prompt) and this is the only
 * thing the plugin uses it for. Entries whose fire time has already passed are
 * dropped rather than posted late: doc 13 §2.5's rule is that a notification which
 * missed its moment is worse than no notification at all.
 */
class BootReceiver : BroadcastReceiver() {

	companion object {
		private const val TAG = "SlacumNative"
	}

	override fun onReceive(context: Context, intent: Intent) {
		val action = intent.action ?: return
		if (action != Intent.ACTION_BOOT_COMPLETED &&
			action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
			action != "android.intent.action.QUICKBOOT_POWERON"
		) {
			return
		}
		try {
			val armed = NotificationCenter(context.applicationContext)
				.replayAfterBoot(System.currentTimeMillis())
			Log.i(TAG, "re-armed $armed notification(s) after boot")
		} catch (e: Exception) {
			Log.w(TAG, "boot replay failed: ${e.message}")
		}
	}
}
