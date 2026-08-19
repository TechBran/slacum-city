class_name SaveService
extends Node
## Player-facing save slots for the app shell (doc 13 §2.2). One JSON file per
## slot under `user://saves/`, written atomically (temp + rename), carrying its
## own meta header so a load screen can list slots without deserializing a city.
##
## This is the SHELL's slot layer, not doc 08's generation ladder. Doc 08's
## `SaveManager` owns envelopes, digests, retention and the corruption gate for
## the *active* city; this service owns "slot 2 is my Tuesday save" and the
## Android pause autosave. When doc 08's manager lands under the shell, this
## file's storage half is what gets replaced — the five-method API stays.
##
## Constitution §3: this is `game/`, so wall-clock reads (`Time`) are legal
## here and illegal in `sim/`. The sim is passed in, never imported: the only
## methods called on it are `canonical_capture()` and `restore_state()`, plus
## three read-only property lookups for the meta header (guarded with `in`, so
## any object exposing them works).

## Emitted after a successful write of any slot, including autosaves.
signal saved(meta: Dictionary)
## Emitted after a slot has been restored into a sim.
signal loaded(slot: int)
## Emitted when a save, load or delete could not complete. `reason` is one of
## `invalid_slot`, `no_dir`, `write_failed`, `rename_failed`, `delete_failed`,
## `missing`, `unreadable`, `bad_json`, `no_state`.
signal failed(slot: int, reason: String)

const SAVE_DIR := "user://saves"
const FILE_TEMPLATE := "slot_%d.json"
const TEMP_SUFFIX := ".tmp"
## Slots the UI may address. 0 is reserved for the lifecycle autosave.
const MAX_SLOTS := 8
const AUTOSAVE_SLOT := 0
## …and its shadow. The autosave **alternates** between these two (doc 13 §2.11):
## every write lands on whichever is older, so the newer one is always a city
## that was complete a moment ago. The rename in `_write_atomic` already makes a
## torn file impossible, but it cannot help with the failure above it — a save
## that is structurally perfect and semantically wrong, written moments before
## the process died. One slot cannot survive that. Two always can.
##
## Slot 7 rather than 1 because `data/ui.json.save_slots.count` is 3: the shadow
## sits outside every slot the player can see, so it can never overwrite a save
## someone meant to keep.
const AUTOSAVE_SHADOW_SLOT := 7
## Bumped only when the envelope around `state` changes; `state` itself is
## versioned by the sim's own sections.
const FORMAT_VERSION := 1
## Meta lives first in the file so `list_slots()` can read a header instead of
## a whole city. Generous enough for the fixed five-key dictionary.
const META_SCAN_BYTES := 4096

## Where slots live. Overridable so tests never touch a real player profile
## (same convention as `SaveManager.base_dir`, doc 08).
var base_dir: String = SAVE_DIR
## Optional: the shell registers a Callable returning the UI save section
## (doc 12 §3.2 — overlay prefs, settings, tutorial progress). When set, every
## save carries it and `last_loaded_ui` hands it back after a load, so the
## tutorial never restarts on a city that already finished it.
var ui_provider: Callable = Callable()
## The `ui` section of the most recent successful load. A boot-time restore
## happens before the UI exists; the shell applies this once it does.
var last_loaded_ui: Dictionary = {}
## Reason string for the last failure, "" after a success. Useful for UI that
## wants the detail without connecting to `failed`.
var last_error: String = ""
## Unix seconds of the last successful autosave, 0 if none this session.
var last_autosave_unix: int = 0
## Which half of the rotation the last autosave landed on, -1 if none yet.
var last_autosave_slot: int = -1


func _ready() -> void:
	_ensure_dir()


# ----------------------------------------------------------------- save path

## Capture `sim` and commit it to `slot`. Returns the meta dictionary
## {slot, saved_at_unix, day_index, population, treasury} on success, or an
## EMPTY dictionary on failure (check `last_error` / the `failed` signal).
func save_slot(sim: Object, slot: int) -> Dictionary:
	if not _valid_slot(slot):
		return _fail_dict(slot, "invalid_slot")
	if sim == null or not sim.has_method("canonical_capture"):
		return _fail_dict(slot, "no_state")
	if not _ensure_dir():
		return _fail_dict(slot, "no_dir")

	var meta := _meta_of(sim, slot)
	var state: Dictionary = sim.call("canonical_capture")
	var ui_json := "{}"
	if ui_provider.is_valid():
		var ui_state: Variant = ui_provider.call()
		if ui_state is Dictionary:
			ui_json = JSON.stringify(ui_state)
	# Concatenated rather than stringified as one dictionary so `meta` is
	# guaranteed to sit in the first bytes of the file — that is the whole
	# reason `list_slots()` is cheap. JSON key order is otherwise unspecified.
	var text := "{\"format\":%d,\"meta\":%s,\"ui\":%s,\"state\":%s}" % [
		FORMAT_VERSION, JSON.stringify(meta), ui_json, JSON.stringify(state)]
	var reason := _write_atomic(_path(slot), text)
	if reason != "":
		return _fail_dict(slot, reason)
	last_error = ""
	saved.emit(meta)
	return meta


## Lifecycle autosave (doc 13 §2.2 step 2): commit the live city to the autosave
## rotation. Never throws, never blocks the caller on a result — listen to
## `saved` / `failed` if you need one.
##
## The write lands on [next_autosave_slot], which is whichever half of the
## rotation is older. That single decision is what makes an unclean exit
## survivable: whatever happens to this write, the *other* slot still holds the
## city as it was one autosave ago.
func autosave(sim: Object) -> void:
	var slot := next_autosave_slot()
	var meta := save_slot(sim, slot)
	if not meta.is_empty():
		last_autosave_unix = int(meta["saved_at_unix"])
		last_autosave_slot = slot


## The two slots the autosave alternates between, in rotation order.
static func autosave_slots() -> Array[int]:
	return [AUTOSAVE_SLOT, AUTOSAVE_SHADOW_SLOT]


## Where the next autosave will land: the older of the pair, or an empty one.
##
## Derived from the files themselves rather than from a counter, because a
## counter is state that can be lost exactly when it matters — after a crash,
## which is the one case this rotation exists for.
func next_autosave_slot() -> int:
	var oldest := AUTOSAVE_SLOT
	var oldest_at := -1
	for slot: int in autosave_slots():
		if not FileAccess.file_exists(_path(slot)):
			return slot
		# Header only, and quiet. Header only because this runs inside the pause
		# sequence, where doc 13 §2.2 budgets 250 ms for everything and parsing
		# two whole cities to read two timestamps would spend it on nothing.
		# Quiet because an unparseable half reports `saved_at_unix = 0`, which
		# makes it the oldest and therefore the next to be overwritten — the right
		# answer, and not a load failure to report to the player.
		var at := _meta_quiet(slot)
		if oldest_at < 0 or at < oldest_at:
			oldest_at = at
			oldest = slot
	return oldest


## The newest autosave that actually loads — the answer `CrashSentinel` asks for
## after an unclean exit. -1 when neither half is readable.
##
## "Readable" here means the whole envelope parses and carries a `state`
## dictionary, which is a full read of the file rather than its header: after a
## crash the cheap check is the wrong one, because the file that is about to be
## offered is the one most likely to be damaged.
func last_good_autosave_slot() -> int:
	var best := -1
	var best_at := -1
	for slot: int in autosave_slots():
		# Deliberately NOT `_read_envelope`: that reports every miss through the
		# `failed` signal, and a health check is not a failed load. A damaged
		# shadow slot is an expected finding here, not an error to surface.
		var envelope := _envelope_quiet(slot)
		if envelope.is_empty() or not (envelope.get("state", null) is Dictionary):
			continue
		var at := 0
		var meta: Variant = envelope.get("meta", {})
		if meta is Dictionary:
			at = int((meta as Dictionary).get("saved_at_unix", 0))
		if at >= best_at:
			best_at = at
			best = slot
	return best


## `saved_at_unix` from a slot's header, or 0 when there is nothing readable
## there. Reads `META_SCAN_BYTES`, never the city.
func _meta_quiet(slot: int) -> int:
	var file := FileAccess.open(_path(slot), FileAccess.READ)
	if file == null:
		return 0
	var head := file.get_buffer(META_SCAN_BYTES).get_string_from_utf8()
	file = null
	return int(_extract_meta(head).get("saved_at_unix", 0))


## A full parse that reports nothing — the health-check read.
func _envelope_quiet(slot: int) -> Dictionary:
	if not _valid_slot(slot) or not FileAccess.file_exists(_path(slot)):
		return {}
	var file := FileAccess.open(_path(slot), FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file = null
	var parsed: Variant = _parse_quiet(text)
	return parsed if parsed is Dictionary else {}


# ----------------------------------------------------------------- load path

## Restore `slot` into `sim`. Returns false and leaves `sim` untouched if the
## slot is missing or unreadable.
func load_slot(sim: Object, slot: int) -> bool:
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	if sim == null or not sim.has_method("restore_state"):
		_fail_dict(slot, "no_state")
		return false
	var envelope := _read_envelope(slot)
	if envelope.is_empty():
		return false
	var state: Variant = envelope.get("state", null)
	if not (state is Dictionary):
		_fail_dict(slot, "no_state")
		return false
	sim.call("restore_state", state)
	var ui_state: Variant = envelope.get("ui", {})
	last_loaded_ui = ui_state if ui_state is Dictionary else {}
	last_error = ""
	loaded.emit(slot)
	return true


## The slot holding the newest save — manual or autosave, whichever the player
## touched last — or -1 when nothing is saved. This is what a plain launch
## resumes from: the most recent save IS the city.
func latest_slot() -> int:
	var best := -1
	var best_at := -1
	for meta in list_slots():
		var at := int(meta.get("saved_at_unix", 0))
		if at > best_at:
			best_at = at
			best = int(meta.get("slot", -1))
	return best


## Session restore: load the newest save into `sim`. Returns the slot loaded,
## or -1 when there was nothing (a genuinely new city) or nothing would load —
## the caller treats both as "fresh founding".
##
## Newest-first with a fallback, because the newest save is the one a crash was
## most likely to damage. With the autosave rotation (`AUTOSAVE_SHADOW_SLOT`) the
## second candidate is normally the previous autosave, so the cost of a bad write
## is one autosave interval of play rather than the city.
func load_latest(sim: Object) -> int:
	var candidates := list_slots()
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("saved_at_unix", 0)) > int(b.get("saved_at_unix", 0)))
	for meta: Dictionary in candidates:
		var slot := int(meta.get("slot", -1))
		if slot >= 0 and load_slot(sim, slot):
			return slot
	return -1


## Every occupied slot's meta, ascending by slot index. Reads only each file's
## header, so a load screen costs bytes, not a deserialize.
func list_slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in MAX_SLOTS:
		if not FileAccess.file_exists(_path(slot)):
			continue
		var meta := _read_meta(slot)
		if not meta.is_empty():
			out.append(meta)
	return out


## Remove a slot (and any temp file orphaned by a kill mid-write).
## Returns true if the slot file is gone afterwards.
func delete_slot(slot: int) -> bool:
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	var path := _path(slot)
	if FileAccess.file_exists(path + TEMP_SUFFIX):
		DirAccess.remove_absolute(path + TEMP_SUFFIX)
	if not FileAccess.file_exists(path):
		return true
	DirAccess.remove_absolute(path)
	var gone := not FileAccess.file_exists(path)
	if not gone:
		_fail_dict(slot, "delete_failed")
	return gone


## True if the slot holds a readable save.
func has_slot(slot: int) -> bool:
	return _valid_slot(slot) and FileAccess.file_exists(_path(slot))


func slot_path(slot: int) -> String:
	return _path(slot)


# ----------------------------------------------------------------- internals

func _path(slot: int) -> String:
	return "%s/%s" % [base_dir, FILE_TEMPLATE % slot]


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < MAX_SLOTS


func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(base_dir):
		return true
	return DirAccess.make_dir_recursive_absolute(base_dir) == OK


## Atomic commit: the reader only ever sees a complete file, because the
## rename is the commit point and a rename within one directory is atomic on
## every filesystem Android ships. A kill mid-write leaves the previous slot
## intact plus one `.tmp` orphan, which the next write or delete clears.
func _write_atomic(path: String, text: String) -> String:
	var tmp := path + TEMP_SUFFIX
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return "write_failed"
	file.store_string(text)
	file.flush()
	file = null  # close before renaming
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return "rename_failed"
	return ""


func _meta_of(sim: Object, slot: int) -> Dictionary:
	return {
		"slot": slot,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"day_index": _day_index(sim),
		"population": _int_prop(_sub(sim, "population"), "city_population"),
		"treasury": _int_prop(_sub(sim, "treasury"), "balance"),
	}


func _day_index(sim: Object) -> int:
	var clock := _sub(sim, "clock")
	if clock != null and clock.has_method("day_index"):
		return int(clock.call("day_index"))
	return 0


static func _sub(owner: Object, property: String) -> Object:
	if owner == null or not (property in owner):
		return null
	var value: Variant = owner.get(property)
	if value is Object:
		return value as Object
	return null


static func _int_prop(owner: Object, property: String) -> int:
	if owner == null or not (property in owner):
		return 0
	return int(owner.get(property))


## Whole-file parse — only the load path pays for this.
func _read_envelope(slot: int) -> Dictionary:
	var path := _path(slot)
	if not FileAccess.file_exists(path):
		return _fail_dict(slot, "missing")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail_dict(slot, "unreadable")
	var text := file.get_as_text()
	file = null
	var parsed: Variant = _parse_quiet(text)
	# An empty dictionary is indistinguishable from this function's failure
	# return, so it is rejected here rather than reported as a stale error.
	if not (parsed is Dictionary) or (parsed as Dictionary).is_empty():
		return _fail_dict(slot, "bad_json")
	return parsed


## `JSON.parse_string()` pushes an engine error on malformed input; a corrupt
## save is an expected outcome here, not an engine fault, so parse through an
## instance and read the status instead.
static func _parse_quiet(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


## Header-only read for `list_slots()`: pull the leading bytes and brace-match
## the `meta` object out of them. Falls back to a full parse if the header is
## not where we put it (a hand-edited or pre-format-1 file).
func _read_meta(slot: int) -> Dictionary:
	var file := FileAccess.open(_path(slot), FileAccess.READ)
	if file == null:
		return _fail_dict(slot, "unreadable")
	var head := file.get_buffer(META_SCAN_BYTES).get_string_from_utf8()
	file = null
	var meta := _extract_meta(head)
	if not meta.is_empty():
		meta["slot"] = slot  # the file name is the authority on identity
		return meta
	var envelope := _read_envelope(slot)
	var fallback: Variant = envelope.get("meta", {})
	if fallback is Dictionary and not (fallback as Dictionary).is_empty():
		var out: Dictionary = fallback
		out["slot"] = slot
		return out
	return _fail_dict(slot, "bad_json")


static func _extract_meta(head: String) -> Dictionary:
	var key := head.find("\"meta\":")
	if key < 0:
		return {}
	var start := head.find("{", key)
	if start < 0:
		return {}
	# The meta object holds numbers only, so brace counting cannot be fooled
	# by a brace inside a string value.
	var depth := 0
	for i in range(start, head.length()):
		var c := head[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				var parsed: Variant = _parse_quiet(head.substr(start, i - start + 1))
				return parsed if parsed is Dictionary else {}
	return {}


func _fail_dict(slot: int, reason: String) -> Dictionary:
	last_error = reason
	failed.emit(slot, reason)
	return {}
