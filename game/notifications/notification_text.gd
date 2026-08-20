class_name NotificationText
extends RefCounted
## The copy half of a push (doc 13 §3.1.1, resolved against G-8).
##
## A plan travels as **keys**, never sentences: `n_<notify_id>_title` /
## `n_<notify_id>_body`, doc 08 §3.3's convention. This class is the last step
## before the platform, where a key plus its arguments becomes the two lines the
## player reads on their lock screen.
##
## **Why the copy is not in `data/notifications_text.json`.** Doc 13 §3.1.1 gave
## itself a second string table; report G-8 then made `data/strings.en.json` the
## one table for the whole game, and doc 12 §5 records the outcome — doc 13 renders
## `n_<event>_title/_body` *from `data/strings.en.json`*. Two tables would mean a
## push and its in-app row could drift apart by one careless edit, which is the
## precise failure G-8 exists to prevent. So there is one table, and this class
## reads it directly rather than reaching up into `ui/` for `UIConfig` — `game/`
## may not depend on `ui/` (constitution §3).
##
## **What is deliberately absent: the clock.** Doc 13 §2.6 ships every alarm
## inexact, so Doze may slip a fire by a quarter of an hour. Copy that said
## "at 19:00" would therefore be a lie roughly one time in four; copy that says
## "in about 3 hours" is true whenever it arrives. `assert_no_clock_times()` is the
## test hook that keeps it that way.

const STRINGS_PATH := "res://data/strings.en.json"
## Android truncates hard in the collapsed row; anything past this is padding the
## player will never see, and a body that needs more than this is a screen.
const TITLE_MAX := 60
const BODY_MAX := 240

var errors: PackedStringArray = []

var _strings: Dictionary = {}


func _init(strings: Dictionary = {}) -> void:
	_strings = strings


static func load_from_files(path: String = STRINGS_PATH) -> NotificationText:
	var store := NotificationText.new()
	if not FileAccess.file_exists(path):
		store.errors.append("missing %s" % path)
		return store
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		store.errors.append("cannot parse %s" % path)
		return store
	store._strings = parsed
	return store


func has(key: String) -> bool:
	return _strings.get(key, null) is String


## `{named}` substitution, plus the `_one` singular the table already carries for
## the counted strings. A missing key renders as the key itself — visible, ugly
## and greppable, which is what `tests/test_android_notifications.gd` asserts
## against so an unkeyed event can never ship as a blank notification.
func render(key: String, args: Dictionary = {}) -> String:
	var template := _template(key, args)
	if template == "":
		return key
	var text := template
	for name: String in args:
		text = text.replace("{%s}" % name, str(args[name]))
	return text


## Title and body for one plan, already truncated to what Android will show.
func render_plan(plan: Dictionary) -> Dictionary:
	var args: Variant = plan.get("args", {})
	var arg_dict: Dictionary = args if args is Dictionary else {}
	return {
		"title": _clip(render(str(plan.get("title_key", "")), arg_dict), TITLE_MAX),
		"body": _clip(render(str(plan.get("body_key", "")), arg_dict), BODY_MAX),
	}


## The user-visible name of an Android channel — what the player sees in system
## settings, forever, because a channel's name is fixed at creation. Falls back to
## the class id so a missing string is a bad label, never a missing channel.
func channel_name(class_id: String) -> String:
	var key := "ui_notif_channel_%s" % class_id.to_lower()
	return render(key) if has(key) else class_id


func _template(key: String, args: Dictionary) -> String:
	var value: Variant = _strings.get(key, null)
	if not (value is String):
		return ""
	var base: String = value
	var one: Variant = _strings.get(key + "_one", null)
	if not (one is String) or args.is_empty():
		return base
	return (one as String) if _count_of(base, args) == 1 else base


## The number an `_one` variant switches on: the single numeric argument the
## template names. Two numbers means the file did not say which noun is counted,
## and the plural form is the safe answer for every count except one.
static func _count_of(template: String, args: Dictionary) -> int:
	var found := -2147483648
	for name: String in args:
		if not template.contains("{%s}" % name):
			continue
		var value: Variant = args[name]
		var count := -2147483648
		if value is int:
			count = int(value)
		elif value is float:
			count = int(round(float(value)))
		if count == -2147483648:
			continue
		if found != -2147483648:
			return -2147483648
		found = count
	return found


static func _clip(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	return text.substr(0, limit - 1).strip_edges() + "…"


## Every `n_*` string that names a wall-clock time, which doc 13 §2.6 forbids
## because the alarm behind it is inexact. Empty is compliant.
func clock_time_offenders() -> PackedStringArray:
	var out: PackedStringArray = []
	var regex := RegEx.new()
	regex.compile("\\b([01]?[0-9]|2[0-3]):[0-5][0-9]\\b")
	var keys: Array = _strings.keys()
	keys.sort()
	for raw: Variant in keys:
		var key := str(raw)
		if not key.begins_with("n_"):
			continue
		var value: Variant = _strings[key]
		if value is String and regex.search(value as String) != null:
			out.append(key)
	return out
