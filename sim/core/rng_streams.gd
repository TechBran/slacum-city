class_name RngStreams
extends RefCounted
## Named deterministic RNG streams (constitution §5).
## Each stochastic system draws ONLY from its own stream so systems don't
## perturb each other's sequences. Seed + state are persisted in saves.

## `street` joined in Wave 15 for doc 06 §2.16's opportunity layer. Adding a
## name is a SAFE change to every existing stream and that is the whole point of
## the derivation below: each stream's seed is `hash(master_seed + ":" + name)`,
## so a new name draws its own sequence and perturbs nobody's. What it does move
## is `serialize()`'s key set — one more entry in the `rng` block — which is why
## the city section takes a rung (doc 08 §2.8 v7) rather than growing quietly.
##
## `contracts` joined in Wave 19 for doc 03 §2.5b's commissions board, on exactly
## the same terms and with the same consequence: a new name perturbs no existing
## stream and moves `serialize()`'s key set, so the city section takes another
## rung (doc 08 §2.8 v9) and all four `profile_sim` baselines are re-recorded
## with the cause published (report 98 §60 RR-170).
##
## `land_works` joined in Wave 25 for doc 03 §2.8b's excavation yield — what the
## crews find while they dig a block out. Same terms again, and the same
## consequence: it perturbs no existing stream (its seed is
## `hash(master_seed + ":land_works")`) and it moves `serialize()`'s key set, so
## the city section takes another rung (doc 08 §2.8 v10) and all four
## `profile_sim` baselines are re-recorded with the cause A/B-isolated
## (report 98 §69 RR-210, doc 92 §66.6). **One draw per find** — two randf()s
## per credited phase, the band roll and the bonus roll, in that fixed order, so
## the sequence is a pure function of which phases completed and when.
const STREAM_NAMES: Array[String] = [
	"weather", "incidents", "crime", "failures", "director", "traffic",
	"street", "contracts", "land_works", "misc",
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
