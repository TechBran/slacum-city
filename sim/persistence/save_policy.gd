class_name SavePolicy
extends RefCounted
## The `save` block of `data/persistence.json` (doc 08 §8), parsed once.
##
## Before this class the retention ladder lived as a `const` inside
## `SaveManager` and the shell's slot layer had no policy at all — which is
## precisely how the project ended up with two save formats. Both writers now
## take one of these, so "how many generations do we keep" has exactly one
## answer and a test can change it without touching a file.
##
## `load_from_files()` is the only path that touches `FileAccess` (the same
## convention as `BuildingCatalog` / `CostCurves`), and its result is cached:
## `SaveService` builds up to `MAX_SLOTS` managers and none of them should pay
## for a re-parse.

## Doc 08 §2.7. Slot A is the active generation, so the array's first entry is
## the active's own age (0) and entries B..F are the history ladder.
const DEFAULT_SLOT_AGES: Array[int] = [0, 0, 1800, 21600, 86400, 604800]
const DATA_PATH := "res://data/persistence.json"

## Envelope version this build writes (doc 08 §2.8). Documentation only — the
## authority is `SaveManager.CURRENT_SCHEMA_VERSION`, because the ladder that
## has to agree with it is code. `tests/test_save_manager.gd` asserts they match.
var current_schema_version: int = 1
## `%d` is the slot index; doc 08 §2.5's `user://saves/slot0/` with the index
## spelled out.
var slot_path: String = "user://saves/slot_%d"
## Where format-1 files written before the unification still live.
var legacy_slot_file: String = "user://saves/slot_%d.json"
var device_settings_path: String = "user://settings.cfg"
var compression: String = "zstd"
var autosave_interval_real_seconds: int = 300
var snapshot_budget_ms: int = 25
var encode_write_budget_ms: int = 120
var load_budget_ms: int = 400
var blocking_save_wait_ms: int = 400
var max_unpinned_generations: int = 6
var max_pinned_generations: int = 2
## Minimum real-seconds age for history slots B..F, in ladder order.
var history_slot_min_age_s: Array[int] = [0, 1800, 21600, 86400, 604800]
var premigration_keep_launches: int = 3
var quarantine_max_files: int = 3
var repair_threshold_frac: float = 0.02
var max_entities_sane: int = 200000
## Non-empty when the file was present but something in it was unusable. The
## policy is still returned fully populated — a bad tunable must never be the
## reason a city cannot be written.
var errors: PackedStringArray = []

static var _cached: SavePolicy = null


## Defaults only. Every field above is already the documented value, so this is
## just a named constructor for the "no data file" case.
static func defaults() -> SavePolicy:
	return SavePolicy.new()


static func from_dict(data: Dictionary) -> SavePolicy:
	var policy := SavePolicy.new()
	var save: Dictionary = data.get("save", {}) if data.get("save") is Dictionary else {}
	policy.current_schema_version = _int_or(save, "current_schema_version",
			policy.current_schema_version)
	policy.slot_path = _str_or(save, "slot_path", policy.slot_path)
	policy.legacy_slot_file = _str_or(save, "legacy_slot_file", policy.legacy_slot_file)
	policy.device_settings_path = _str_or(save, "device_settings_path",
			policy.device_settings_path)
	policy.compression = _str_or(save, "compression", policy.compression)
	policy.autosave_interval_real_seconds = _int_or(save, "autosave_interval_real_seconds",
			policy.autosave_interval_real_seconds)
	policy.snapshot_budget_ms = _int_or(save, "snapshot_budget_ms", policy.snapshot_budget_ms)
	policy.encode_write_budget_ms = _int_or(save, "encode_write_budget_ms",
			policy.encode_write_budget_ms)
	policy.load_budget_ms = _int_or(save, "load_budget_ms", policy.load_budget_ms)
	policy.blocking_save_wait_ms = _int_or(save, "blocking_save_wait_ms",
			policy.blocking_save_wait_ms)
	policy.max_unpinned_generations = maxi(1, _int_or(save, "max_unpinned_generations",
			policy.max_unpinned_generations))
	policy.max_pinned_generations = maxi(0, _int_or(save, "max_pinned_generations",
			policy.max_pinned_generations))
	policy.premigration_keep_launches = _int_or(save, "premigration_keep_launches",
			policy.premigration_keep_launches)
	policy.quarantine_max_files = maxi(1, _int_or(save, "quarantine_max_files",
			policy.quarantine_max_files))
	policy.repair_threshold_frac = _float_or(save, "repair_threshold_frac",
			policy.repair_threshold_frac)
	policy.max_entities_sane = _int_or(save, "max_entities_sane", policy.max_entities_sane)

	var ages: Array[int] = []
	var raw: Variant = save.get("retention_slot_age_real_seconds", null)
	if raw is Array:
		for value: Variant in (raw as Array):
			ages.append(int(value))
	if ages.is_empty():
		ages = DEFAULT_SLOT_AGES.duplicate()
	else:
		# The first entry is slot A — the active generation, whose age is 0 by
		# definition. The ladder this class publishes is B..F.
		ages.remove_at(0)
	# The ladder can never outrun the count it fills: active + history ≤ the cap.
	while ages.size() > policy.max_unpinned_generations - 1:
		ages.remove_at(ages.size() - 1)
	policy.history_slot_min_age_s = ages
	return policy


## Parses `data/persistence.json` once per process. Pass `force` to re-read
## after a test has written a different file.
static func load_from_files(path: String = DATA_PATH, force: bool = false) -> SavePolicy:
	if _cached != null and not force and path == DATA_PATH:
		return _cached
	var policy: SavePolicy
	if not FileAccess.file_exists(path):
		policy = SavePolicy.defaults()
		policy.errors.append("missing %s — save policy defaults in force" % path)
	else:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			policy = SavePolicy.from_dict(parsed)
		else:
			policy = SavePolicy.defaults()
			policy.errors.append("cannot parse %s" % path)
	if path == DATA_PATH:
		_cached = policy
	return policy


func is_valid() -> bool:
	return errors.is_empty()


func slot_dir(slot: int) -> String:
	return slot_path % slot


func legacy_slot_path(slot: int) -> String:
	return legacy_slot_file % slot


static func _int_or(data: Dictionary, key: String, fallback: int) -> int:
	return int(data[key]) if data.has(key) else fallback


static func _float_or(data: Dictionary, key: String, fallback: float) -> float:
	return float(data[key]) if data.has(key) else fallback


static func _str_or(data: Dictionary, key: String, fallback: String) -> String:
	return String(data[key]) if data.has(key) else fallback
