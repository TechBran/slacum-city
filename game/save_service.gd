class_name SaveService
extends Node
## Player-facing save slots for the app shell — doc 13 §2.2's API riding doc
## 08's storage (§2.5–§2.9).
##
## **What changed and why.** This service used to own its own format: one flat
## JSON file per slot, a two-slot autosave shadow, and a `format` integer with
## no ladder behind it. Doc 08's `SaveManager` owned the real thing — generation
## files, a `manifest.json` commit point, SHA-256 digests, a retention ladder, a
## quarantine and a seven-check load gate — and was reachable from nowhere. Two
## save formats, one game (doc 91 §8, rows 2.5/2.7/2.8/2.9). The five-method API
## below is unchanged; everything underneath it is now `SaveManager`.
##
##     user://saves/slot_3/manifest.json     <- the commit point AND the header
##     user://saves/slot_3/gen_000042.sav    <- zstd JSON envelope, digested
##     user://saves/slot_3/quarantine/…      <- candidates that failed the gate
##     user://saves/slot_3.json              <- format 1, read-only, still loads
##
## **The header trick moved, it did not die.** The old file put `meta` in its
## first bytes so a load screen could list slots without deserializing a city.
## The envelope's body is sorted-key by law (doc 08 §2.5 — that is what makes
## the digest meaningful), so `meta` can no longer be first inside it. It is
## written into `manifest.active.meta` instead: still one small uncompressed
## read per slot, and now it survives a body that is corrupt *and* unparseable,
## which the old brace-scan did not.
##
## **The autosave shadow is gone; the ladder subsumes it.** `AUTOSAVE_SHADOW_SLOT`
## existed because one slot cannot survive a save that is structurally perfect
## and semantically wrong. Doc 08 §2.7's ladder answers the same failure with
## six generations spread across 30 minutes / 6 hours / 24 hours / 7 days, each
## digest-verified on the way back in, and `load_newest()` walking them in
## order. That is the shadow, five deep, with a checksum. Slot 7 is a player
## slot again.
##
## Constitution §3: this is `game/`, so wall-clock reads (`Time`) are legal here
## and illegal in `sim/` — which is why `SaveManager` takes `real_unix` as a
## parameter. The sim is passed in, never imported: the only methods called on
## it are `canonical_capture()` and `restore_state()`, plus read-only property
## lookups for the header (guarded with `in`, so any object exposing them works).

## Emitted after a successful write of any slot, including autosaves.
signal saved(meta: Dictionary)
## Emitted after a slot has been restored into a sim.
signal loaded(slot: int)
## Emitted when a save, load or delete could not complete. `reason` is one of
## `invalid_slot`, `no_dir`, `write_failed`, `rename_failed`, `delete_failed`,
## `missing`, `unreadable`, `bad_json`, `no_state`, and — new with the doc 08
## gate — `corrupt` (every candidate generation failed its digest or structural
## check) and `downgrade` (the save was written by a newer build of the app).
signal failed(slot: int, reason: String)

const SAVE_DIR := "user://saves"
## Format-1 layout: one flat file per slot. Read-only now; see [load_slot].
const FILE_TEMPLATE := "slot_%d.json"
const TEMP_SUFFIX := ".tmp"
## Slots the UI may address. 0 is reserved for the lifecycle autosave.
const MAX_SLOTS := 8
const AUTOSAVE_SLOT := 0
## The slot the retired autosave shadow used. Kept for one reason only: a phone
## upgrading from a build that alternated has a format-1 file here, and it may
## be the newer half. It is never written again — the first autosave after the
## upgrade lands on [AUTOSAVE_SLOT] and the ladder takes over — but until then
## [last_good_autosave_slot] must still be able to find the city that is
## actually there. See the class docs for why the alternation went away.
const LEGACY_AUTOSAVE_SHADOW_SLOT := 7
## The envelope this build writes. 1 = the flat `{format,meta,ui,state}` file;
## 2 = a doc 08 generation ladder under `slot_N/`. Format 1 is still READ (the
## migration path in [_load_legacy]) and never written again.
const FORMAT_VERSION := 2
const LEGACY_FORMAT_VERSION := 1
## Meta lived first in the format-1 file so `list_slots()` could read a header
## instead of a whole city. Only the legacy reader needs this now.
const META_SCAN_BYTES := 4096

## Save-body sections (doc 08 §3.1). Milestone 1 has one sim section, not the
## registry's twenty — see `DictSection`, and `_city_section_version` for the
## hook `sim/city_sim.gd` fills as it splits.
const META_SECTION := &"meta"
const CITY_SECTION := &"city"
const UI_SECTION := &"ui"
## Fallback when the sim exposes no `save_section_version()` of its own.
const CITY_SECTION_VERSION := 1
const UI_SECTION_VERSION := 1
const META_SECTION_VERSION := 1

## slot:int -> SaveManager. Declared before [base_dir] because that property's
## setter clears it.
var _managers: Dictionary = {}

## Where slots live. Overridable so tests never touch a real player profile.
## Assigning it drops every cached slot manager, because the managers are bound
## to paths under the old root.
var base_dir: String = SAVE_DIR:
	set(value):
		base_dir = value
		_managers.clear()
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
## Which slot the last autosave landed on, -1 if none yet. Always
## [AUTOSAVE_SLOT] now that the ladder replaced the two-slot rotation; kept
## because `CrashSentinel` and the lifecycle node both read it.
var last_autosave_slot: int = -1

## Doc 08 §2.9 recovery bookkeeping, set by every successful [load_slot]:
## true when the generation that loaded was NOT the manifest's active one.
var last_load_recovered: bool = false
## Sim-minutes between the slot's high-water mark and the generation that
## actually loaded — doc 08 §2.9's "you lost about N minutes" figure.
var last_load_lost_minutes: int = 0
## 1 when the last successful load came from a format-1 file, 2 from the ladder.
var last_load_format: int = 0
## Structural repairs the last load had to make (doc 08 §2.9's repair notes).
var repair_notes: PackedStringArray = []

## Doc 08 §8's `save` block. Injectable so a test can shorten the ladder.
var policy: SavePolicy = SavePolicy.load_from_files()


func _ready() -> void:
	_ensure_dir()


# ----------------------------------------------------------------- save path

## Capture `sim` and commit it to `slot`. Returns the meta dictionary
## {slot, saved_at_unix, day_index, population, treasury} on success, or an
## EMPTY dictionary on failure (check `last_error` / the `failed` signal).
##
## `reason` is doc 08 §2.7's checkpoint reason and rides the manifest entry:
## `manual` from the save screen, `autosave` from the timer, `pause`/`quit`
## from the lifecycle. `pre_migration` and `pre_catchup` additionally PIN the
## generation, which is why they are never swept.
func save_slot(sim: Object, slot: int, reason: String = "manual") -> Dictionary:
	if not _valid_slot(slot):
		return _fail_dict(slot, "invalid_slot")
	if sim == null or not sim.has_method("canonical_capture"):
		return _fail_dict(slot, "no_state")
	if not _ensure_dir():
		return _fail_dict(slot, "no_dir")

	var meta := _meta_of(sim, slot, reason)
	var manager := _manager(slot)
	var city := DictSection.new(CITY_SECTION, _city_section_version(sim))
	city.payload = sim.call("canonical_capture")
	city.migrator = _city_migrator(sim)
	var ui := DictSection.new(UI_SECTION, UI_SECTION_VERSION)
	if ui_provider.is_valid():
		var ui_state: Variant = ui_provider.call()
		if ui_state is Dictionary:
			ui.payload = ui_state
	var meta_section := DictSection.new(META_SECTION, META_SECTION_VERSION)
	meta_section.payload = meta.duplicate()
	manager.register_section(city)
	manager.register_section(ui)
	manager.register_section(meta_section)

	# The header rides the manifest (see the class docs): one small
	# uncompressed file per slot is what keeps `list_slots()` cheap.
	var result := manager.request_save(reason, _sim_time_minutes(sim),
			int(meta["saved_at_unix"]), {"meta": meta.duplicate()})
	if not bool(result["ok"]):
		# The generation write and the manifest commit fail differently, and the
		# difference matters: a failed generation wrote nothing, a failed
		# manifest left an orphan and the PREVIOUS save still active.
		return _fail_dict(slot,
				"rename_failed" if result["reason_code"] == &"E_MANIFEST_WRITE"
				else "write_failed")
	last_error = ""
	saved.emit(meta)
	return meta


## Lifecycle autosave (doc 13 §2.2 step 2): commit the live city to the
## autosave slot. Never throws, never blocks the caller on a result — listen to
## `saved` / `failed` if you need one.
##
## One slot, because doc 08 §2.7's generation ladder inside it already keeps the
## previous city — and five more behind that, spread out to a week. An unclean
## exit that ate this write falls through to the generation before it, which is
## what the two-slot shadow used to buy at a quarter of the depth and with no
## digest to prove the fallback was ever whole.
func autosave(sim: Object) -> void:
	var meta := save_slot(sim, AUTOSAVE_SLOT, "autosave")
	if not meta.is_empty():
		last_autosave_unix = int(meta["saved_at_unix"])
		last_autosave_slot = AUTOSAVE_SLOT


## The slots the autosave uses. A one-element array since the ladder replaced
## the rotation; kept as an array because callers iterate it.
static func autosave_slots() -> Array[int]:
	return [AUTOSAVE_SLOT]


## Where the next autosave will land. Always [AUTOSAVE_SLOT] — the depth that
## used to come from alternating slots now comes from the generation ladder
## inside this one.
func next_autosave_slot() -> int:
	return AUTOSAVE_SLOT


## The newest autosave that actually loads — the answer `CrashSentinel` asks for
## after an unclean exit. -1 when nothing in the autosave slot is readable.
##
## "Loads" means a full doc 08 §2.9 candidate walk: decompress, envelope parse,
## SHA-256 match, version range, structural check. It is a PROBE — nothing is
## quarantined, nothing is deserialized, and no failure is reported through the
## `failed` signal, because a damaged checkpoint found by a health check is an
## expected finding and not an error to put in front of a player.
func last_good_autosave_slot() -> int:
	if _has_ladder(AUTOSAVE_SLOT) \
			and bool(_manager(AUTOSAVE_SLOT).peek_newest()["ok"]):
		return AUTOSAVE_SLOT
	# Nothing in the ladder, so this is either a fresh install or a phone that
	# has not autosaved since the upgrade. On the latter the pre-unification
	# rotation's two halves are both still on disk and either may be the newer
	# complete city — the exact question this method was written to answer, and
	# it must keep answering it for those files even though nothing writes them.
	var best := -1
	var best_at := -1
	for slot: int in [AUTOSAVE_SLOT, LEGACY_AUTOSAVE_SHADOW_SLOT]:
		var envelope := _legacy_envelope_quiet(slot)
		if not (envelope.get("state", null) is Dictionary):
			continue
		var at := 0
		var meta: Variant = envelope.get("meta", {})
		if meta is Dictionary:
			at = int((meta as Dictionary).get("saved_at_unix", 0))
		if at >= best_at:
			best_at = at
			best = slot
	return best


# ----------------------------------------------------------------- load path

## Restore `slot` into `sim`. Returns false and leaves `sim` untouched if the
## slot is missing or nothing in it survives the load gate.
##
## Two readers, one decision: a slot written by this build is a generation
## ladder; a slot written before the unification is a format-1 file. The ladder
## wins when both exist, because the ladder is newer by construction — the
## legacy file is never written again once a slot has been saved.
##
## And when the ladder is exhausted, the format-1 file is the last candidate,
## in exactly the spirit of doc 08 §2.9's walk: it is a pinned checkpoint that
## predates every generation. The difference for a player whose ladder is
## somehow entirely unreadable is "your city is gone" versus "your city is back
## to before the update", and it costs one `file_exists` to offer.
func load_slot(sim: Object, slot: int) -> bool:
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	if sim == null or not sim.has_method("restore_state"):
		_fail_dict(slot, "no_state")
		return false
	var has_legacy := FileAccess.file_exists(_legacy_path(slot))
	if _has_ladder(slot):
		if _load_ladder(sim, slot, not has_legacy):
			return true
		if not has_legacy:
			return false
	if has_legacy:
		var recovered := _has_ladder(slot)   # the ladder was tried and lost
		if not _load_legacy(sim, slot):
			return false
		last_load_recovered = last_load_recovered or recovered
		return true
	_fail_dict(slot, "missing")
	return false


## Doc 08 §2.5–§2.9's path: candidate walk, digest gate, quarantine, section
## ladders, structural repair. `report_failure` is false when a further
## candidate remains outside the ladder — the reason is still recorded in
## `last_error`, but a failure the caller is about to recover from is not one
## the player needs a toast about.
func _load_ladder(sim: Object, slot: int, report_failure: bool = true) -> bool:
	var manager := _manager(slot)
	var city := DictSection.new(CITY_SECTION, _city_section_version(sim))
	city.migrator = _city_migrator(sim)
	var ui := DictSection.new(UI_SECTION, UI_SECTION_VERSION)
	var meta_section := DictSection.new(META_SECTION, META_SECTION_VERSION)
	manager.register_section(city)
	manager.register_section(ui)
	manager.register_section(meta_section)

	var result := manager.load_newest()
	if not bool(result["ok"]):
		_refuse(slot, _reason_for(result), report_failure)
		return false
	if city.restored_is_empty():
		# A body with no `city` section is a save of nothing. The structural
		# repair would hand us an empty default and the sim would restore into
		# a blank city, which is worse than refusing.
		_refuse(slot, "no_state", report_failure)
		return false

	sim.call("restore_state", city.restored)
	last_loaded_ui = {} if ui.restored_is_empty() else ui.restored
	var payload: Dictionary = result["payload"]
	last_load_recovered = bool(payload["recovered"])
	last_load_lost_minutes = int(payload["lost_minutes"])
	last_load_format = FORMAT_VERSION
	repair_notes = manager.repair_notes.duplicate()
	last_error = ""
	loaded.emit(slot)
	return true


## Format 1 → format 2 reader (doc 08 §2.8's rules applied to the shell's own
## envelope). The file is `{"format":1,"meta":{…},"ui":{…},"state":{…}}` with
## no digest and no generation, so the gate it gets is the one it can pass:
## the envelope parses, the format is not from the future, and `state` is a
## dictionary. It is left EXACTLY as found — the next save to this slot writes
## a generation beside it, and the untouched original is that migration's
## `pre_migration` checkpoint at zero cost.
func _load_legacy(sim: Object, slot: int) -> bool:
	var envelope := _read_legacy_envelope(slot)
	if envelope.is_empty():
		return false
	# Doc 08 §2.8's downgrade rule: a file from a newer build is refused and
	# not touched, rather than half-read into a city.
	var format := int(envelope.get("format", LEGACY_FORMAT_VERSION))
	if format > FORMAT_VERSION:
		_fail_dict(slot, "downgrade")
		return false
	var state: Variant = envelope.get("state", null)
	if not (state is Dictionary):
		_fail_dict(slot, "no_state")
		return false
	sim.call("restore_state", state)
	var ui_state: Variant = envelope.get("ui", {})
	last_loaded_ui = ui_state if ui_state is Dictionary else {}
	last_load_recovered = false
	last_load_lost_minutes = 0
	last_load_format = format
	repair_notes = PackedStringArray()
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
## Newest-first with a fallback ACROSS slots, on top of doc 08's fallback
## WITHIN a slot: a damaged newest generation costs one autosave interval, and
## only a slot whose whole ladder is unreadable costs the slot.
func load_latest(sim: Object) -> int:
	var candidates := list_slots()
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("saved_at_unix", 0)) > int(b.get("saved_at_unix", 0)))
	for meta: Dictionary in candidates:
		var slot := int(meta.get("slot", -1))
		if slot >= 0 and load_slot(sim, slot):
			return slot
	return -1


## Every occupied slot's meta, ascending by slot index. Reads one manifest per
## slot — a few hundred bytes — never a city.
func list_slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in MAX_SLOTS:
		var meta := _slot_meta(slot)
		if not meta.is_empty():
			out.append(meta)
	return out


## Remove a slot: the generation ladder, its quarantine, the legacy file, and
## any temp orphaned by a kill mid-write. Returns true if the slot is gone.
func delete_slot(slot: int) -> bool:
	if not _valid_slot(slot):
		_fail_dict(slot, "invalid_slot")
		return false
	_managers.erase(slot)
	_remove_tree(_slot_dir(slot))
	var legacy := _legacy_path(slot)
	if FileAccess.file_exists(legacy + TEMP_SUFFIX):
		DirAccess.remove_absolute(legacy + TEMP_SUFFIX)
	if FileAccess.file_exists(legacy):
		DirAccess.remove_absolute(legacy)
	var gone := not has_slot(slot)
	if not gone:
		_fail_dict(slot, "delete_failed")
	return gone


## True if the slot holds a save — a committed generation or a legacy file.
func has_slot(slot: int) -> bool:
	return _valid_slot(slot) \
			and (_has_ladder(slot) or FileAccess.file_exists(_legacy_path(slot)))


## The file that holds this slot's city right now: the active generation when
## the ladder is live, the format-1 file when it is all the slot has, and the
## legacy path (which may not exist) when the slot is empty. Consumers that
## want a byte count or a path to show want this one.
func slot_path(slot: int) -> String:
	var active := _active_generation_file(slot)
	if active != "":
		return "%s/%s" % [_slot_dir(slot), active]
	return _legacy_path(slot)


## The slot's generation directory (doc 08 §2.5), whether or not it exists.
func slot_dir(slot: int) -> String:
	return _slot_dir(slot)


## The doc 08 manager behind a slot — its `read_manifest()`, `peek_newest()`
## and `repair_notes` are what a recovery dialog needs. The five-method API
## above is what everything else should use.
func manager_for(slot: int) -> SaveManager:
	return _manager(slot) if _valid_slot(slot) else null


# ----------------------------------------------------------------- internals

func _slot_dir(slot: int) -> String:
	return "%s/slot_%d" % [base_dir, slot]


func _legacy_path(slot: int) -> String:
	return "%s/%s" % [base_dir, FILE_TEMPLATE % slot]


func _manifest_path(slot: int) -> String:
	return _slot_dir(slot) + "/manifest.json"


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < MAX_SLOTS


func _has_ladder(slot: int) -> bool:
	return FileAccess.file_exists(_manifest_path(slot))


## Managers are cached because `SaveManager._init` creates directories, and a
## load screen asks about every slot.
func _manager(slot: int) -> SaveManager:
	if not _managers.has(slot):
		_managers[slot] = SaveManager.new(_slot_dir(slot), policy)
	return _managers[slot]


func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(base_dir):
		return true
	return DirAccess.make_dir_recursive_absolute(base_dir) == OK


func _sim_time_minutes(sim: Object) -> int:
	var clock := _sub(sim, "clock")
	if clock != null and clock.has_method("sim_time_minutes"):
		return int(clock.call("sim_time_minutes"))
	return 0


## The sim's own section ladder position, when it has one. Duck-typed so
## `sim/city_sim.gd` can grow `save_section_version()` / `migrate_save_section()`
## on its own schedule without this file changing again.
func _city_section_version(sim: Object) -> int:
	if sim != null and sim.has_method("save_section_version"):
		return int(sim.call("save_section_version"))
	return CITY_SECTION_VERSION


func _city_migrator(sim: Object) -> Callable:
	if sim != null and sim.has_method("migrate_save_section"):
		return func(data: Dictionary, from_version: int) -> Dictionary:
			var out: Variant = sim.call("migrate_save_section", data, from_version)
			return out if out is Dictionary else data
	return Callable()


## The five documented header keys, plus doc 08 §3.2's `meta` identity fields.
## `has_all` on the five is what the UI checks, so the additions are additive
## by construction.
func _meta_of(sim: Object, slot: int, reason: String) -> Dictionary:
	return {
		"slot": slot,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"day_index": _day_index(sim),
		"population": _int_prop(_sub(sim, "population"), "city_population"),
		"treasury": _int_prop(_sub(sim, "treasury"), "balance"),
		"format": FORMAT_VERSION,
		"save_reason": reason,
		"sim_time_minutes": _sim_time_minutes(sim),
		"app_version": str(ProjectSettings.get_setting("application/config/version", "")),
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


## Doc 08 §2.9's per-candidate failure codes, mapped onto this service's
## reasons. The distinction the UI needs is "this file is not a save" versus
## "this file is a save that did not survive", and only the first is a JSON
## problem.
func _reason_for(result: Dictionary) -> String:
	var failures: Array = (result.get("payload", {}) as Dictionary).get("failures", [])
	if failures.is_empty():
		return "missing"
	var first := String((failures[0] as Dictionary).get("reason", ""))
	match first:
		"unreadable": return "unreadable"
		"bad_envelope": return "bad_json"
		"downgrade": return "downgrade"
		_: return "corrupt"


# --------------------------------------------------------------- slot headers

## A slot's header without deserializing a city: the manifest's `meta` record,
## or the legacy file's leading bytes when the slot predates the ladder.
func _slot_meta(slot: int) -> Dictionary:
	var meta := _ladder_meta(slot)
	if not meta.is_empty():
		return meta
	if FileAccess.file_exists(_legacy_path(slot)):
		return _legacy_meta(slot)
	return {}


func _ladder_meta(slot: int) -> Dictionary:
	if not _has_ladder(slot):
		return {}
	var parsed: Variant = _parse_quiet(
			FileAccess.get_file_as_string(_manifest_path(slot)))
	if not (parsed is Dictionary):
		return {}
	var active: Variant = (parsed as Dictionary).get("active", null)
	if not (active is Dictionary):
		return {}
	var entry: Dictionary = active
	var meta: Variant = entry.get("meta", null)
	var out: Dictionary = (meta as Dictionary).duplicate() if meta is Dictionary else {}
	if out.is_empty():
		# A manifest written without a header — hand-edited, or by a build
		# older than this one. Pay for the decompress rather than hide the slot.
		out = _meta_from_generation(slot, String(entry.get("file", "")))
	if out.is_empty():
		return {}
	out["slot"] = slot  # the directory name is the authority on identity
	if not out.has("saved_at_unix"):
		out["saved_at_unix"] = int(entry.get("real_unix", 0))
	return out


## The expensive header read: decompress the generation and take its `meta`
## section. Only reached when the manifest has no header of its own — a
## hand-edited manifest, or one written by a build older than this file's
## header convention. A full parse rather than a brace-scan because the whole
## file has already been decompressed by then, so the scan would be a guess
## bought at no saving.
func _meta_from_generation(slot: int, file_name: String) -> Dictionary:
	if file_name == "":
		return {}
	var path := "%s/%s" % [_slot_dir(slot), file_name]
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {}
	var text := file.get_as_text()
	file = null
	var envelope: Variant = _parse_quiet(text)
	if not (envelope is Dictionary):
		return {}
	var body: Variant = (envelope as Dictionary).get("body", null)
	if not (body is Dictionary):
		return {}
	var meta: Variant = (body as Dictionary).get(String(META_SECTION), null)
	return (meta as Dictionary).duplicate() if meta is Dictionary else {}


## Format-1 header read: pull the leading bytes and brace-match the `meta`
## object out of them. The whole reason that file put `meta` first, and the
## only caller of [_extract_meta] that remains.
func _legacy_meta(slot: int) -> Dictionary:
	var file := FileAccess.open(_legacy_path(slot), FileAccess.READ)
	if file == null:
		return _fail_dict(slot, "unreadable")
	var head := file.get_buffer(META_SCAN_BYTES).get_string_from_utf8()
	file = null
	var meta := _extract_meta(head)
	if not meta.is_empty():
		meta["slot"] = slot
		meta["format"] = LEGACY_FORMAT_VERSION
		return meta
	var envelope := _read_legacy_envelope(slot)
	var fallback: Variant = envelope.get("meta", {})
	if fallback is Dictionary and not (fallback as Dictionary).is_empty():
		var out: Dictionary = fallback
		out["slot"] = slot
		out["format"] = LEGACY_FORMAT_VERSION
		return out
	return _fail_dict(slot, "bad_json")


static func _extract_meta(head: String) -> Dictionary:
	var key := head.find("\"meta\":")
	if key < 0:
		return {}
	var start := head.find("{", key)
	if start < 0:
		return {}
	# The meta object holds numbers and short identifiers only, so brace
	# counting cannot be fooled by a brace inside a string value.
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


# ---------------------------------------------------------------- legacy IO

## Whole-file parse of a format-1 slot — only the legacy load path pays for it.
func _read_legacy_envelope(slot: int) -> Dictionary:
	var path := _legacy_path(slot)
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


## A format-1 parse that reports nothing — the health-check read.
func _legacy_envelope_quiet(slot: int) -> Dictionary:
	if not _valid_slot(slot) or not FileAccess.file_exists(_legacy_path(slot)):
		return {}
	var file := FileAccess.open(_legacy_path(slot), FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file = null
	var parsed: Variant = _parse_quiet(text)
	return parsed if parsed is Dictionary else {}


## `JSON.parse_string()` pushes an engine error on malformed input; a corrupt
## save is an expected outcome here, not an engine fault, so parse through an
## instance and read the status instead.
static func _parse_quiet(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _active_generation_file(slot: int) -> String:
	if not _has_ladder(slot):
		return ""
	var parsed: Variant = _parse_quiet(
			FileAccess.get_file_as_string(_manifest_path(slot)))
	if not (parsed is Dictionary):
		return ""
	var active: Variant = (parsed as Dictionary).get("active", null)
	if not (active is Dictionary):
		return ""
	return String((active as Dictionary).get("file", ""))


## Depth-first removal. `DirAccess.remove_absolute` refuses a non-empty
## directory, and a slot directory has a `quarantine/` child.
##
## The listing is taken in full BEFORE anything is deleted. Removing entries
## inside a `list_dir_begin()` walk mutates the directory the walk is reading,
## and the entries it then skips are files that silently survive — a
## `delete_slot` that leaves the city behind for the next launch to resume,
## which is the worst possible way for this to fail.
static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var files: Array[String] = []
	var dirs: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for child in files:
		DirAccess.remove_absolute(path + "/" + child)
	for child in dirs:
		_remove_tree(path + "/" + child)
	DirAccess.remove_absolute(path)


func _fail_dict(slot: int, reason: String) -> Dictionary:
	last_error = reason
	failed.emit(slot, reason)
	return {}


## Record a refusal, announcing it only when nothing further will be tried.
func _refuse(slot: int, reason: String, announce: bool) -> void:
	if announce:
		_fail_dict(slot, reason)
	else:
		last_error = reason
