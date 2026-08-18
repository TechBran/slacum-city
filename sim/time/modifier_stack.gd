class_name ModifierStack
extends RefCounted
## Multiplicative modifier sources on named channels (doc 01 §2.6).
## Sources multiply in a fixed order — sorted by (source_kind_rank, source_id) —
## so floating-point product order is deterministic regardless of push order.

const SOURCE_RANK := {
	&"weather": 0, &"scheduled_event": 1, &"district": 2, &"policy": 3, &"debug": 4,
}

# Each entry: {kind: StringName, id: String, mults: Dictionary[channel -> float]}
var _sources: Array[Dictionary] = []
## Bumped on every mutation; lets consumers cache derived products per revision.
var revision: int = 0


func push_source(kind: StringName, source_id: String, mults: Dictionary) -> void:
	assert(SOURCE_RANK.has(kind), "unknown modifier source kind: " + String(kind))
	remove_source(kind, source_id)
	_sources.append({"kind": kind, "id": source_id, "mults": mults})
	_sources.sort_custom(_source_less)
	revision += 1


func remove_source(kind: StringName, source_id: String) -> void:
	for i in range(_sources.size() - 1, -1, -1):
		if _sources[i]["kind"] == kind and _sources[i]["id"] == source_id:
			_sources.remove_at(i)
			revision += 1


func clear() -> void:
	_sources.clear()
	revision += 1


func source_count() -> int:
	return _sources.size()


func product_for(channel_name: String) -> float:
	var product := 1.0
	for source in _sources:
		var mults: Dictionary = source["mults"]
		if mults.has(channel_name):
			product *= float(mults[channel_name])
	return product


static func _source_less(a: Dictionary, b: Dictionary) -> bool:
	var ra: int = SOURCE_RANK[a["kind"]]
	var rb: int = SOURCE_RANK[b["kind"]]
	if ra != rb:
		return ra < rb
	return String(a["id"]) < String(b["id"])
