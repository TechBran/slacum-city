class_name AudioConfig
extends RefCounted
## The single reader for `data/audio.json` (doc 11 §2.15) and the generated
## asset manifest. Pure `RefCounted`, and parsing is handed a Dictionary, so
## `AudioEvents` is constructible from a fixture with no file IO — exactly the
## `UIConfig` / `BuildingCatalog` shape the rest of the codebase uses.
##
## Constitution §3: no magic numbers in code. Every level, cooldown, distance and
## curve below lives in the JSON; the accessors take a fallback only so a
## malformed file degrades to a quiet game rather than a crash, and `errors` is
## non-empty in that case.

const AUDIO_JSON_PATH := "res://data/audio.json"
const MANIFEST_PATH := "res://game/audio/generated/manifest.json"

var errors: PackedStringArray = []

var _audio: Dictionary = {}
var _manifest: Dictionary = {}


func _init(audio: Dictionary = {}, manifest: Dictionary = {}) -> void:
	_audio = audio
	_manifest = manifest


static func load_from_files(audio_path: String = AUDIO_JSON_PATH,
		manifest_path: String = "") -> AudioConfig:
	var cfg := AudioConfig.new()
	cfg._audio = AudioConfig._parse(audio_path, cfg.errors, true)
	var manifest := manifest_path
	if manifest == "":
		manifest = str(cfg._audio.get("manifest", MANIFEST_PATH))
	# The manifest is generated art, not tunables: its absence means "the assets
	# have not been built yet", which is a silent game and not a broken one.
	cfg._manifest = AudioConfig._parse(manifest, cfg.errors, false)
	return cfg


static func _parse(path: String, sink: PackedStringArray, required: bool) -> Dictionary:
	if not FileAccess.file_exists(path):
		if required:
			sink.append("missing %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		sink.append("cannot parse %s" % path)
		return {}
	return parsed


func is_valid() -> bool:
	return errors.is_empty()


func audio_data() -> Dictionary:
	return _audio


func manifest() -> Dictionary:
	return _manifest


func section(name: String) -> Dictionary:
	var value: Variant = _audio.get(name, {})
	return value if value is Dictionary else {}


func mix() -> Dictionary:
	return section("mix")


func world() -> Dictionary:
	return section("world")


func pool() -> Dictionary:
	return section("pool")


func cues() -> Dictionary:
	return section("cues")


func beds() -> Dictionary:
	return section("beds")


func buses() -> Array:
	var value: Variant = _audio.get("buses", [])
	return value if value is Array else []


## The event → cue rules, `_comment` entries stripped: a rule without a `type`
## is documentation, and the matcher should never have to know that.
func rules() -> Array:
	var out: Array = []
	var raw: Variant = _audio.get("events", [])
	if not (raw is Array):
		return out
	for entry: Variant in raw:
		if entry is Dictionary and str((entry as Dictionary).get("type", "")) != "":
			out.append(entry)
	return out


func cue(cue_id: String) -> Dictionary:
	var value: Variant = cues().get(cue_id, {})
	return value if value is Dictionary else {}


func bed(bed_id: String) -> Dictionary:
	var value: Variant = beds().get(bed_id, {})
	return value if value is Dictionary else {}


## Bed ids in a stable order — `beds()` is a JSON object, and a mix that depends
## on dictionary order is a mix that changes when someone reformats the file.
func bed_ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in beds():
		if str(key).begins_with("_"):
			continue
		out.append(str(key))
	out.sort()
	return out


func cue_ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in cues():
		if str(key).begins_with("_"):
			continue
		out.append(str(key))
	out.sort()
	return out


func asset_root() -> String:
	return str(_audio.get("asset_root", "res://game/audio/generated/"))


## `res://…/<stream>.wav`, the one place the extension is spelled.
func stream_path(stream_name: String) -> String:
	if stream_name == "":
		return ""
	return "%s%s.wav" % [asset_root(), stream_name]


## Manifest row for a generated asset (seconds, bytes, loop, seam ratios…).
func asset(name: String) -> Dictionary:
	var raw: Variant = _manifest.get("assets", [])
	if not (raw is Array):
		return {}
	for entry: Variant in raw:
		if entry is Dictionary and str((entry as Dictionary).get("name", "")) == name:
			return entry
	return {}


func assets() -> Array:
	var raw: Variant = _manifest.get("assets", [])
	return raw if raw is Array else []


static func get_num(source: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = source.get(key, null)
	if value is float or value is int:
		return float(value)
	return fallback


static func get_int(source: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = source.get(key, null)
	if value is float or value is int:
		return int(value)
	return fallback
