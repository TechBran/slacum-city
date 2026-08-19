class_name CrashSentinel
extends RefCounted
## Did the last session end, or did it stop? (doc 13 §2.11)
##
## Android kills backgrounded processes with no callback whatsoever — no
## `_exit_tree`, no `WM_CLOSE_REQUEST`, nothing. So a crash and a routine
## out-of-memory kill and a clean quit are indistinguishable *after* the fact, and
## the only way to tell them apart is to leave a mark **before**:
##
##     boot   → write `user://runtime/session_open.flag`
##     pause  → delete it (the pause sequence has already committed the city)
##     boot   → flag still there?  the last session did not get that far.
##
## That is the whole mechanism, and its cheapness is the point: no SDK, no
## `INTERNET` permission, no Data Safety declaration, nothing to receive telemetry
## because **nothing is sent**. What it produces is a local breadcrumb file the
## player can share from Settings → "Report a problem" through an Android share
## intent, which keeps the choice of channel — and of whether to share at all —
## with them.
##
## **The hook point for real crash reporting is [breadcrumb_path]**, and it is
## documented rather than built: the day a network reporter is worth its cost
## (doc 13 §2.11 ranks Sentry post-alpha), it uploads that file and the Data
## Safety form changes in the same commit. Play Console's Android vitals covers
## native crashes and ANRs for free in the meantime, which is why this exists to
## catch the GDScript half rather than to replace them.
##
## **What an unclean exit changes.** One thing, and only one: the shell is told
## which save to offer. `SaveService` alternates its autosave between two slots
## precisely so a session that died mid-write cannot have eaten the only copy —
## the older slot is always a complete, previously-verified city. [recovery_slot]
## is that answer.

const RUNTIME_DIR := "user://runtime"
const LOGS_DIR := "user://logs"
const FLAG_NAME := "session_open.flag"
## doc 13 §8 `diagnostics.breadcrumb_ring` / `breadcrumb_event_count`.
const INCIDENT_RING := 5
const BREADCRUMB_CAPACITY := 64

## Where the flag and the incident ring live. Overridable so tests never touch a
## real player profile (same convention as `SaveService.base_dir`).
var runtime_dir: String = RUNTIME_DIR
var logs_dir: String = LOGS_DIR
## Injected so a test can stamp a fixed second and assert on the filename.
var wall_clock: Callable = func() -> float: return Time.get_unix_time_from_system()

## True when [boot] found the previous session's flag still in place.
var last_exit_unclean: bool = false
## Path of the incident file [boot] wrote, or "" when the exit was clean.
var incident_path: String = ""
## Cumulative count across the install, persisted beside the flag.
var unclean_exits: int = 0

var _breadcrumbs: Array[Dictionary] = []


## Call once at launch, before the city is loaded. Returns true when the previous
## session ended uncleanly — which is the shell's cue to offer [recovery_slot]
## rather than the newest save.
func boot() -> bool:
	_ensure_dirs()
	var flag := _flag_path()
	last_exit_unclean = FileAccess.file_exists(flag)
	incident_path = ""
	if last_exit_unclean:
		unclean_exits = _read_unclean_count() + 1
		incident_path = _write_incident()
		_prune_incidents()
	else:
		unclean_exits = _read_unclean_count()
	_write_flag()
	return last_exit_unclean


## Call from the pause sequence, after the autosave has been requested. Deleting
## the flag *after* the save is deliberate: a kill between the two is a clean exit
## with a committed city, and marking it unclean would send the player to an older
## save for no reason.
func mark_clean_exit() -> void:
	var flag := _flag_path()
	if FileAccess.file_exists(flag):
		DirAccess.remove_absolute(flag)


## One line of context for the next incident file. Ring-buffered, so a long
## session costs a fixed amount of memory.
func note(kind: String, detail: Variant = null) -> void:
	_breadcrumbs.append({
		"at_unix": int(wall_clock.call()),
		"kind": kind,
		"detail": str(detail) if detail != null else "",
	})
	while _breadcrumbs.size() > BREADCRUMB_CAPACITY:
		_breadcrumbs.remove_at(0)


func breadcrumbs() -> Array[Dictionary]:
	return _breadcrumbs.duplicate()


## Which save the shell should offer after an unclean exit: the newest autosave
## that actually **loads**, which after a torn write is the other half of the
## rotation. -1 when there is nothing to recover.
##
## Duck-typed on purpose — this class knows the question, `SaveService` owns the
## files, and neither has to import the other.
func recovery_slot(save_service: Object) -> int:
	if save_service == null:
		return -1
	if save_service.has_method("last_good_autosave_slot"):
		var slot := int(save_service.call("last_good_autosave_slot"))
		if slot >= 0:
			return slot
	if save_service.has_method("latest_slot"):
		return int(save_service.call("latest_slot"))
	return -1


## The file a future crash reporter would upload, and today the file Settings →
## "Report a problem" shares. "" until an unclean exit has been detected.
func breadcrumb_path() -> String:
	return incident_path


func flag_exists() -> bool:
	return FileAccess.file_exists(_flag_path())


# ----------------------------------------------------------------- internals

func _flag_path() -> String:
	return "%s/%s" % [runtime_dir, FLAG_NAME]


func _counter_path() -> String:
	return "%s/unclean_exits.txt" % runtime_dir


func _ensure_dirs() -> void:
	for dir: String in [runtime_dir, logs_dir]:
		if not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)


func _write_flag() -> void:
	var file := FileAccess.open(_flag_path(), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"opened_at_unix": int(wall_clock.call()),
		"version": _app_version(),
	}))
	file.flush()


func _read_unclean_count() -> int:
	if not FileAccess.file_exists(_counter_path()):
		return 0
	var text := FileAccess.get_file_as_string(_counter_path()).strip_edges()
	return text.to_int() if text.is_valid_int() else 0


func _write_unclean_count() -> void:
	var file := FileAccess.open(_counter_path(), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(str(unclean_exits))
	file.flush()


## The breadcrumb file: everything a person could use to reproduce a crash, and
## nothing that identifies the player. No account, no location, no ids — which is
## what lets the Data Safety form say "no data collected" and stay true even
## after the file is shared, because the *player* chooses the recipient.
func _write_incident() -> String:
	var at := int(wall_clock.call())
	var path := "%s/incident_%d.json" % [logs_dir, at]
	var payload := {
		"schema_version": 1,
		"detected_at_unix": at,
		"reason": "unclean_exit",
		"app_version": _app_version(),
		"engine": str(Engine.get_version_info().get("string", "")),
		"device_model": OS.get_model_name(),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"unclean_exits": unclean_exits,
		"previous_session": _read_flag_payload(),
		"breadcrumbs": _breadcrumbs.duplicate(),
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(payload, "  "))
	file.flush()
	file = null
	_write_unclean_count()
	return path


func _read_flag_payload() -> Dictionary:
	if not FileAccess.file_exists(_flag_path()):
		return {}
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(_flag_path()))
	return parsed if parsed is Dictionary else {}


## Ring of 5, oldest first out. A crash loop must not fill the device.
func _prune_incidents() -> void:
	var dir := DirAccess.open(logs_dir)
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("incident_") \
				and entry.ends_with(".json"):
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	# Names are `incident_<unix>.json`, so lexical order is chronological for
	# every timestamp of the same width — and unix seconds stay ten digits until
	# 2286, which is a comfortable margin for a ring of five.
	files.sort()
	while files.size() > INCIDENT_RING:
		var victim: String = files.pop_front()
		DirAccess.remove_absolute("%s/%s" % [logs_dir, victim])


func _app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))
