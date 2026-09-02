class_name PermissionFlow
extends RefCounted
## The `POST_NOTIFICATIONS` state machine (doc 13 §2.7).
##
## Android 13 made notifications opt-in, and it made the opt-in **one-shot**: two
## dismissals and the system stops showing the dialog for the life of the install.
## There is no way back except the app's page in system settings. So the single
## most valuable thing this class does is *not ask yet*.
##
##     never_asked ──[trigger + rationale accepted]──▶ system dialog ──▶ granted
##          │                                                │
##          └──[Not now]──▶ denied ──[≥7 days AND a P1 was   └──▶ denied
##                                    missed offline]───────────────┘
##                              …at most `reprompt_max` (2) times, ever
##                          denied_permanent ──▶ never prompt again; offer settings
##
## Two rules make the difference between a permission a player grants and one they
## reflexively dismiss:
##
## * **Ask when the answer matters.** The trigger is not launch — a cold prompt
##   converts badly and burns one of the two chances. It is the first moment the
##   shell has something real to schedule: doc 13 §2.7 names the end of onboarding
##   step 10 (the first construction timer), doc 08 §2.13.4 names the first
##   resolved incident. Either satisfies `note_trigger()`; the shell decides which
##   fires first in practice.
## * **Re-ask only with evidence.** A second prompt is allowed only after seven
##   days AND only when the player has just come back to a city where a P1
##   happened while they were away — because then the modal can say something true
##   and specific: *"You missed a citywide blackout. Want a heads-up next time?"*
##
## The class is `RefCounted` and platform-free: it holds the *policy*, and it asks
## an injected `AndroidNative` for the platform state. Off-device every state
## resolves to `unsupported`, `should_prompt()` is false, and nothing prompts —
## which is what the headless runner and the desktop build need.

## The rationale modal should be shown (doc 12 owns the modal itself).
signal rationale_requested(reason: String)
## A decision landed. `state` is one of `AndroidNative.PERMISSION_*`.
signal state_changed(state: String)

## doc 13 §8 `permission_flow`.
const REPROMPT_MAX := 2
const REPROMPT_COOLDOWN_DAYS := 7
const REPROMPT_COOLDOWN_S := float(REPROMPT_COOLDOWN_DAYS) * 86_400.0
## The second prompt has to carry evidence, or it is just nagging.
const REPROMPT_REQUIRES_MISSED_P1 := true

## Why the modal is being shown — doc 12 renders different copy for each.
const REASON_FIRST := "first"
const REASON_MISSED_P1 := "missed_p1"

var native: AndroidNative

## How many times the *system* dialog has been requested, ever.
var asked_count: int = 0
## Unix seconds of the last request, 0 if never.
var last_asked_unix: int = 0
## How many of those were re-prompts (i.e. after the first denial).
var reprompt_count: int = 0
## Set by the shell when a P1 fired while the app was closed and the player did
## not have the permission — the evidence a re-prompt needs. Cleared once used.
var missed_p1_offline: bool = false
## True once the shell has reached a moment worth asking at (§2.7 step 1).
var triggered: bool = false
## Real seconds; injectable so a test can walk seven days in one line.
var wall_clock: Callable = func() -> float: return Time.get_unix_time_from_system()

var _asked_this_session := false


func _init(p_native: AndroidNative = null) -> void:
	native = p_native if p_native != null else AndroidNative.detect()


## The platform's answer, straight through. `unsupported` covers both "API < 33"
## and "no plugin", which the caller should treat identically: there is nothing to
## request, and `notifications_enabled()` is the only truth left.
func state() -> String:
	if native == null:
		return AndroidNative.PERMISSION_UNSUPPORTED
	return native.permission_state()


func notifications_enabled() -> bool:
	return native != null and native.notifications_enabled()


## The shell reached a moment worth asking at: the first scheduled construction
## timer, or the first resolved incident. Idempotent.
func note_trigger() -> void:
	triggered = true


## A P1 fired offline that the player never saw, because the permission was not
## held. The only evidence that earns a second prompt.
func note_missed_p1() -> void:
	missed_p1_offline = true


## Should the rationale modal be shown right now? Answers false for every reason
## it possibly can — that is the point of the class.
func should_prompt(now_unix: float = -1.0) -> bool:
	if not triggered or _asked_this_session:
		return false
	match state():
		AndroidNative.PERMISSION_GRANTED, AndroidNative.PERMISSION_UNSUPPORTED, \
				AndroidNative.PERMISSION_DENIED_PERMANENT:
			# Nothing to gain: already on, no permission to hold, or the system
			# has stopped listening. The last case is why this is checked before
			# the cooldown — a permanently denied app that kept counting down to
			# a re-prompt would show a modal that opens no dialog.
			return false
		AndroidNative.PERMISSION_NEVER_ASKED:
			return true
	# denied: the re-prompt rules apply, all of them.
	if reprompt_count >= REPROMPT_MAX:
		return false
	if REPROMPT_REQUIRES_MISSED_P1 and not missed_p1_offline:
		return false
	var now := now_unix if now_unix >= 0.0 else float(wall_clock.call())
	return now - float(last_asked_unix) >= REPROMPT_COOLDOWN_S


## Ask doc 12 to show the in-game rationale. Returns the reason token it should
## render, or "" when nothing should be shown.
func request_rationale(now_unix: float = -1.0) -> String:
	if not should_prompt(now_unix):
		return ""
	var reason := REASON_MISSED_P1 if missed_p1_offline and asked_count > 0 else REASON_FIRST
	rationale_requested.emit(reason)
	return reason


## The player accepted the rationale: show the system dialog. The answer arrives
## on `AndroidNative.permission_result`, which the shell forwards to [confirm].
func accept(now_unix: float = -1.0) -> bool:
	if native == null:
		return false
	var now := now_unix if now_unix >= 0.0 else float(wall_clock.call())
	asked_count += 1
	if asked_count > 1:
		reprompt_count += 1
	last_asked_unix = int(now)
	_asked_this_session = true
	missed_p1_offline = false
	if not native.request_notification_permission():
		# No platform to ask. Not a denial: the state stays whatever it was, and
		# the session flag stops us looping on a build that can never answer.
		return false
	return true


## The player chose "Not now". Costs one of the two chances, deliberately — a
## dismissal is a decision and pretending otherwise leads to nagging.
func decline(now_unix: float = -1.0) -> void:
	var now := now_unix if now_unix >= 0.0 else float(wall_clock.call())
	asked_count += 1
	if asked_count > 1:
		reprompt_count += 1
	last_asked_unix = int(now)
	_asked_this_session = true
	missed_p1_offline = false
	state_changed.emit(AndroidNative.PERMISSION_DENIED)


## The system dialog's answer, forwarded by the shell.
func confirm(granted: bool) -> void:
	state_changed.emit(AndroidNative.PERMISSION_GRANTED if granted else state())


## The only route left once Android has stopped showing the dialog — what the
## Settings row's "Open system settings" action calls.
func open_system_settings() -> bool:
	return native != null and native.open_app_notification_settings()


## What S10's row should say, as a state token doc 12 renders:
## `on` | `off` | `blocked` | `unavailable`.
func settings_row_state() -> String:
	match state():
		AndroidNative.PERMISSION_GRANTED:
			return "on" if notifications_enabled() else "off"
		AndroidNative.PERMISSION_DENIED_PERMANENT:
			return "blocked"
		AndroidNative.PERMISSION_UNSUPPORTED:
			return "on" if notifications_enabled() else "unavailable"
	return "off"


# ---------------------------------------------------------------------------
# Persistence — doc 13 §3.2 `android.permission`
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	return {
		"section_version": 1,
		"asked_count": asked_count,
		"last_asked_unix": last_asked_unix,
		"reprompt_count": reprompt_count,
	}


func deserialize(data: Dictionary) -> void:
	asked_count = int(data.get("asked_count", 0))
	last_asked_unix = int(data.get("last_asked_unix", 0))
	reprompt_count = int(data.get("reprompt_count", 0))


## …and it persists in `user://settings.cfg`, not in a save slot (doc 08 §2.5
## names doc 13's permission bookkeeping as one of that file's four tenants).
##
## This is the one piece of state where device-scoping is not a convenience but
## the whole correctness argument: Android's two dismissals are spent per
## INSTALL. If the counter rode in the city's save, deleting the city — or
## rolling back to a checkpoint taken before the first prompt — would hand the
## app a third chance it does not have, and the modal would open a system dialog
## that never appears. The player would be asked, would answer, and nothing would
## happen.
func load_device(path: String = DeviceSettings.DEFAULT_PATH) -> void:
	deserialize(DeviceSettings.read_section(path, DeviceSettings.SECTION_PERMISSION))


func save_device(path: String = DeviceSettings.DEFAULT_PATH) -> bool:
	return DeviceSettings.write_section(path, DeviceSettings.SECTION_PERMISSION, serialize())
