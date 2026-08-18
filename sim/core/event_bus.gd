class_name SimEventBus
extends RefCounted
## Sim → outward event channel (constitution §3).
## Systems append plain event dictionaries during a tick; the app shell
## (renderer, UI, offline report builder) drains them after each advance.
## Events are data, never callbacks — the sim never calls into higher layers.

var _events: Array[Dictionary] = []


func emit(event_type: StringName, data: Dictionary = {}) -> void:
	var event := data.duplicate()
	event["type"] = event_type
	_events.append(event)


func drain() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


func pending_count() -> int:
	return _events.size()
