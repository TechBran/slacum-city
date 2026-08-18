class_name CommandQueue
extends RefCounted
## Player intent channel: ui/ → sim/ (constitution §3, doc 01 P01).
## Commands queue between ticks and drain exactly once, at the top of a tick,
## so no command can half-apply mid-simulation. Results carry stable failure
## codes, never display strings (the UI formats them).

var _queue: Array[Dictionary] = []
var _next_seq: int = 1


func submit(command_type: StringName, payload: Dictionary = {}) -> int:
	var seq := _next_seq
	_next_seq += 1
	_queue.append({"seq": seq, "type": command_type, "payload": payload})
	return seq


func pending_count() -> int:
	return _queue.size()


## Drained at P01 in submission order.
func drain() -> Array[Dictionary]:
	var batch := _queue
	_queue = [] as Array[Dictionary]
	return batch


static func ok(payload: Dictionary = {}) -> Dictionary:
	return {"ok": true, "reason_code": &"", "payload": payload}


static func fail(reason_code: StringName, payload: Dictionary = {}) -> Dictionary:
	return {"ok": false, "reason_code": reason_code, "payload": payload}
