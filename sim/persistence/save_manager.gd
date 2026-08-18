class_name SaveManager
extends RefCounted
## Save envelope, atomic writes, manifest commit, retention, load gate
## (doc 08 §2.5–2.9). Generation files are versioned JSON, zstd-compressed on
## disk, SHA-256 digested; the manifest.json rename is the commit point.
##
## Wall-clock time is INJECTED (`real_unix` parameters) — sim/ never reads it
## (constitution §5). File IO uses FileAccess directly for now; the Android
## shell's IFileSink indirection (report C-04) arrives with doc 13 integration.

const CURRENT_SCHEMA_VERSION: int = 1
const MANIFEST_VERSION: int = 1
const QUARANTINE_CAP: int = 3
## Envelope migration ladder (doc 08 §2.8): {from_version: Callable}.
const LADDER: Dictionary = {}

## Retention slot age thresholds in real seconds relative to the active save
## (doc 08 §2.7): B newest other, then C/D/E/F progressively older.
const RETENTION_SLOT_MIN_AGE_S: Array[int] = [0, 1800, 21600, 86400, 604800]

var base_dir: String
var _sections: Array[SaveSection] = []
var repair_notes: PackedStringArray = []


func _init(p_base_dir: String = "user://saves/slot0") -> void:
	base_dir = p_base_dir
	DirAccess.make_dir_recursive_absolute(base_dir + "/quarantine")


func register_section(section: SaveSection) -> void:
	assert(section.section_key() != &"", "section needs a key")
	_sections.append(section)
	_sections.sort_custom(func(a: SaveSection, b: SaveSection) -> bool:
		return String(a.section_key()) < String(b.section_key()))


# ---------------------------------------------------------------- save path

## Snapshot every registered section and commit a new generation.
## `real_unix` is injected by the shell; `reason` per doc 08 §2.7.
func request_save(reason: String, sim_time_minutes: int, real_unix: int) -> Dictionary:
	var manifest := _read_manifest()
	var generation: int = int(manifest.get("next_generation", 1))
	var body := {
		"schema_version": CURRENT_SCHEMA_VERSION,
		"sim_time_minutes": sim_time_minutes,
	}
	for section in _sections:
		var data := section.serialize()
		data["section_version"] = section.section_version()
		body[String(section.section_key())] = data
	var body_text := JSON.stringify(body, "", true, true)
	var digest := _sha256(body_text)
	# Envelope assembled by string concatenation so the hashed bytes are
	# literally the embedded bytes (doc 08 §2.6 step 3).
	var envelope_text := "{\"schema_version\":%d,\"body_sha256\":\"%s\",\"body\":%s}" \
			% [CURRENT_SCHEMA_VERSION, digest, body_text]
	var file_name := "gen_%06d.sav" % generation
	if not _write_compressed_atomic(file_name, envelope_text):
		return CommandQueue.fail(&"E_SAVE_WRITE")

	var entry := {
		"file": file_name, "schema_version": CURRENT_SCHEMA_VERSION,
		"sim_time_minutes": sim_time_minutes, "sha256": digest,
		"real_unix": real_unix, "reason": reason,
		"bytes": envelope_text.length(),
	}
	var history: Array = manifest.get("history", [])
	if manifest.has("active"):
		history.push_front(manifest["active"])
	manifest["manifest_version"] = MANIFEST_VERSION
	manifest["active"] = entry
	manifest["history"] = history
	manifest["high_water_sim_minutes"] = maxi(int(manifest.get("high_water_sim_minutes", 0)), sim_time_minutes)
	manifest["max_seen_unix"] = maxi(int(manifest.get("max_seen_unix", 0)), real_unix)
	manifest["next_generation"] = generation + 1
	if reason == "pre_migration" or reason == "pre_catchup":
		var pinned: Dictionary = manifest.get("pinned", {})
		pinned[reason] = file_name
		manifest["pinned"] = pinned
	_apply_retention(manifest)
	if not _write_manifest_atomic(manifest):
		return CommandQueue.fail(&"E_MANIFEST_WRITE")
	_sweep(manifest)
	return CommandQueue.ok({"file": file_name, "sha256": digest, "generation": generation})


# ---------------------------------------------------------------- load path

## Walk the candidate order with the 7-check gate (doc 08 §2.9).
## Returns {ok, payload:{body, file, recovered, lost_minutes}} or failure.
func load_newest() -> Dictionary:
	repair_notes.clear()
	var manifest := _read_manifest()
	var high_water: int = int(manifest.get("high_water_sim_minutes", 0))
	var candidates: Array[String] = []
	if manifest.has("active"):
		candidates.append(String(manifest["active"]["file"]))
	for entry in manifest.get("history", []):
		candidates.append(String(entry["file"]))
	var pinned: Dictionary = manifest.get("pinned", {})
	for key in ["pre_catchup", "pre_migration"]:
		if pinned.has(key) and not candidates.has(String(pinned[key])):
			candidates.append(String(pinned[key]))
	for file_name in _scan_generations():
		if not candidates.has(file_name):
			candidates.append(file_name)

	var failures: Array = []
	for file_name in candidates:
		var result := _validate_candidate(file_name, high_water)
		if bool(result["ok"]):
			var body: Dictionary = result["body"]
			var recovered: bool = manifest.has("active") \
					and String(manifest["active"]["file"]) != file_name
			var lost := 0
			if recovered:
				lost = maxi(0, high_water - int(body.get("sim_time_minutes", 0)))
			for section in _sections:
				var key := String(section.section_key())
				var data: Dictionary = body.get(key, section.default_section())
				var from_version: int = int(data.get("section_version", 1))
				if from_version < section.section_version():
					data = section.migrate_section(data, from_version)
				section.deserialize(data)
			return CommandQueue.ok({
				"body": body, "file": file_name,
				"recovered": recovered, "lost_minutes": lost,
				"failures": failures,
			})
		failures.append({"file": file_name, "reason": result["reason"]})
		if String(result["reason"]) != "downgrade":
			_quarantine(file_name)
	return CommandQueue.fail(&"E_NO_LOADABLE_SAVE", {"failures": failures})


func _validate_candidate(file_name: String, high_water: int) -> Dictionary:
	var path := base_dir + "/" + file_name
	var file := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {"ok": false, "reason": "unreadable"}
	var text := file.get_as_text()
	file = null
	var envelope: Variant = JSON.parse_string(text)
	if not (envelope is Dictionary) or not envelope.has_all(["schema_version", "body_sha256", "body"]):
		return {"ok": false, "reason": "bad_envelope"}
	# Check 3: the hashed bytes are the embedded bytes — re-extract the body
	# substring rather than re-stringifying (float round-trips differ).
	var body_start := text.find("\"body\":")
	if body_start < 0 or not text.ends_with("}"):
		return {"ok": false, "reason": "bad_envelope"}
	var body_text := text.substr(body_start + 7, text.length() - body_start - 8)
	if _sha256(body_text) != String(envelope["body_sha256"]):
		return {"ok": false, "reason": "sha_mismatch"}
	var version: int = int(envelope["schema_version"])
	if version > CURRENT_SCHEMA_VERSION:
		return {"ok": false, "reason": "downgrade"}
	if version < 1:
		return {"ok": false, "reason": "bad_version"}
	var body: Dictionary = envelope["body"]
	if version < CURRENT_SCHEMA_VERSION:
		body = _migrate(body, version)
	if not _validate_structural(body):
		return {"ok": false, "reason": "structural"}
	if high_water > 0 and int(body.get("sim_time_minutes", 0)) > high_water + 1:
		return {"ok": false, "reason": "time_ahead_of_high_water"}
	return {"ok": true, "body": body}


func _migrate(body: Dictionary, from_version: int) -> Dictionary:
	var version := from_version
	while version < CURRENT_SCHEMA_VERSION:
		assert(LADDER.has(version), "no migration path from v%d" % version)
		body = (LADDER[version] as Callable).call(body)
		version += 1
	body["schema_version"] = version
	return body


func _validate_structural(body: Dictionary) -> bool:
	var sim_minutes: int = int(body.get("sim_time_minutes", -1))
	if sim_minutes < 0:
		return false
	# Doc 01 invariant (constitution §4 as amended): derived minute counter
	# must match the canonical tick counter.
	if body.has("time"):
		var tick_index: int = int((body["time"] as Dictionary).get("tick_index", -1))
		if tick_index >= 0 and sim_minutes != tick_index / 4:
			return false
	for section in _sections:
		var key := String(section.section_key())
		if not body.has(key):
			body[key] = section.default_section()
			repair_notes.append("missing section '%s' replaced with defaults" % key)
	return true


# ---------------------------------------------------------------- retention

func _apply_retention(manifest: Dictionary) -> void:
	var active: Dictionary = manifest["active"]
	var history: Array = manifest.get("history", [])
	history.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["real_unix"]) > int(b["real_unix"]))
	var kept: Array = []
	var used_files: Array[String] = [String(active["file"])]
	for min_age in RETENTION_SLOT_MIN_AGE_S:
		for entry in history:
			var entry_file: String = String(entry["file"])
			if used_files.has(entry_file):
				continue
			if int(active["real_unix"]) - int(entry["real_unix"]) >= min_age:
				kept.append(entry)
				used_files.append(entry_file)
				break
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["real_unix"]) > int(b["real_unix"]))
	manifest["history"] = kept


func _sweep(manifest: Dictionary) -> void:
	var referenced: Array[String] = [String(manifest["active"]["file"])]
	for entry in manifest.get("history", []):
		referenced.append(String(entry["file"]))
	for pinned_file in manifest.get("pinned", {}).values():
		referenced.append(String(pinned_file))
	for file_name in _scan_generations():
		if not referenced.has(file_name):
			DirAccess.remove_absolute(base_dir + "/" + file_name)


func _quarantine(file_name: String) -> void:
	var quarantine_dir := base_dir + "/quarantine"
	var existing: Array[String] = []
	var dir := DirAccess.open(quarantine_dir)
	if dir != null:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if not dir.current_is_dir():
				existing.append(entry)
			entry = dir.get_next()
		dir.list_dir_end()
	existing.sort()
	while existing.size() >= QUARANTINE_CAP:
		DirAccess.remove_absolute(quarantine_dir + "/" + existing.pop_front())
	DirAccess.rename_absolute(base_dir + "/" + file_name, quarantine_dir + "/bad_" + file_name)


# ---------------------------------------------------------------- plumbing

func _scan_generations() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(base_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("gen_") and entry.ends_with(".sav"):
			out.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	out.reverse()  # newest generation number first
	return out


func _read_manifest() -> Dictionary:
	var file := FileAccess.open(base_dir + "/manifest.json", FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_manifest_atomic(manifest: Dictionary) -> bool:
	var tmp := base_dir + "/manifest.json.tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(manifest, "", true))
	file.flush()
	file = null
	return DirAccess.rename_absolute(tmp, base_dir + "/manifest.json") == OK


func _write_compressed_atomic(file_name: String, text: String) -> bool:
	var tmp := base_dir + "/" + file_name + ".tmp"
	var file := FileAccess.open_compressed(tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return false
	file.store_string(text)
	file.flush()
	file = null
	return DirAccess.rename_absolute(tmp, base_dir + "/" + file_name) == OK


static func _sha256(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()
