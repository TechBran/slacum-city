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
## Bumped only when the envelope around `state` changes; `state` itself is
## versioned by the sim's own sections.
const FORMAT_VERSION := 1
## Meta lives first in the file so `list_slots()` can read a header instead of
## a whole city. Generous enough for the fixed five-key dictionary.
const META_SCAN_BYTES := 4096

## Where slots live. Overridable so tests never touch a real player profile
## (same convention as `SaveManager.base_dir`, doc 08).
var base_dir: String = SAVE_DIR
## Reason string for the last failure, "" after a success. Useful for UI that
## wants the detail without connecting to `failed`.
var last_error: String = ""
## Unix seconds of the last successful autosave, 0 if none this session.
var last_autosave_unix: int = 0


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
	# Concatenated rather than stringified as one dictionary so `meta` is
	# guaranteed to sit in the first bytes of the file — that is the whole
	# reason `list_slots()` is cheap. JSON key order is otherwise unspecified.
	var text := "{\"format\":%d,\"meta\":%s,\"state\":%s}" % [
		FORMAT_VERSION, JSON.stringify(meta), JSON.stringify(state)]
	var reason := _write_atomic(_path(slot), text)
	if reason != "":
		return _fail_dict(slot, reason)
	last_error = ""
	saved.emit(meta)
	return meta


## Lifecycle autosave (doc 13 §2.2 step 2): commit the live city to the
## reserved autosave slot. Never throws, never blocks the caller on a result —
## listen to `saved` / `failed` if you need one.
func autosave(sim: Object) -> void:
	var meta := save_slot(sim, AUTOSAVE_SLOT)
	if not meta.is_empty():
		last_autosave_unix = int(meta["saved_at_unix"])


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
	last_error = ""
	loaded.emit(slot)
	return true


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
