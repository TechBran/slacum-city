class_name RngStreams
extends RefCounted
## Named deterministic RNG streams (constitution §5).
## Each stochastic system draws ONLY from its own stream so systems don't
## perturb each other's sequences. Seed + state are persisted in saves.

const STREAM_NAMES: Array[String] = [
	"weather", "incidents", "crime", "failures", "director", "traffic", "misc",
]

var _streams: Dictionary = {}


func _init(master_seed: int = 0) -> void:
	reset(master_seed)


func reset(master_seed: int) -> void:
	_streams.clear()
	for i in STREAM_NAMES.size():
		var rng := RandomNumberGenerator.new()
		# Distinct per-stream seed derived from the master seed.
		rng.seed = hash(str(master_seed) + ":" + STREAM_NAMES[i])
		_streams[STREAM_NAMES[i]] = rng


func stream(stream_name: String) -> RandomNumberGenerator:
	assert(_streams.has(stream_name), "unknown RNG stream: " + stream_name)
	return _streams[stream_name]


## Seed and state are full 64-bit integers; JSON numbers are doubles and lose
## precision above 2^53, so they persist as STRINGS (constitution §5 — a save
## round-trip must never perturb a stream).
func serialize() -> Dictionary:
	var out := {}
	for stream_name in _streams:
		var rng: RandomNumberGenerator = _streams[stream_name]
		out[stream_name] = {"seed": str(rng.seed), "state": str(rng.state)}
	return out


func deserialize(data: Dictionary) -> void:
	for stream_name in _streams:
		if data.has(stream_name):
			var rng: RandomNumberGenerator = _streams[stream_name]
			var entry: Dictionary = data[stream_name]
			rng.seed = _to_int64(entry["seed"])
			rng.state = _to_int64(entry["state"])


static func _to_int64(value: Variant) -> int:
	if value is String:
		return (value as String).to_int()
	return int(value)
