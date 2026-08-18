class_name TimerService
extends RefCounted
## Deadline timers (doc 01 §2.7a): absolute due_tick, immune to rate modifiers.
## Binary min-heap keyed by (due_tick, timer_id); id breaks ties deterministically.

var next_timer_id: int = 1
var _heap: Array[Dictionary] = []


func schedule(kind: StringName, owner: StringName, due_tick: int, payload: Dictionary = {},
		notify_offline: bool = false, period_ticks: int = 0, repeats_left: int = 0) -> int:
	var id := next_timer_id
	next_timer_id += 1
	_push({
		"id": id, "kind": kind, "owner": owner, "due_tick": due_tick,
		"period_ticks": period_ticks, "repeats_left": repeats_left,
		"notify_offline": notify_offline, "payload": payload,
	})
	return id


func cancel(timer_id: int) -> bool:
	for i in _heap.size():
		if int(_heap[i]["id"]) == timer_id:
			_heap[i] = _heap[_heap.size() - 1]
			_heap.pop_back()
			if i < _heap.size():
				_sift_down(_sift_up(i))
			return true
	return false


func pending_count() -> int:
	return _heap.size()


## Pops every timer with due_tick <= t, in (due_tick, id) order.
## Repeating timers are re-armed automatically.
func collect_due(t: int) -> Array[Dictionary]:
	var due: Array[Dictionary] = []
	while not _heap.is_empty() and int(_heap[0]["due_tick"]) <= t:
		var timer: Dictionary = _pop()
		due.append(timer)
		if int(timer["period_ticks"]) > 0 and int(timer["repeats_left"]) != 0:
			var again := timer.duplicate()
			again["due_tick"] = int(timer["due_tick"]) + int(timer["period_ticks"])
			if int(again["repeats_left"]) > 0:
				again["repeats_left"] = int(again["repeats_left"]) - 1
			_push(again)
	return due


func serialize() -> Dictionary:
	var timers := _heap.duplicate(true)
	timers.sort_custom(_timer_less)
	return {"next_timer_id": next_timer_id, "timers": timers}


func deserialize(data: Dictionary) -> void:
	next_timer_id = int(data.get("next_timer_id", 1))
	_heap.clear()
	for timer in data.get("timers", []):
		_push(timer)


static func _timer_less(a: Dictionary, b: Dictionary) -> bool:
	if int(a["due_tick"]) != int(b["due_tick"]):
		return int(a["due_tick"]) < int(b["due_tick"])
	return int(a["id"]) < int(b["id"])


func _push(timer: Dictionary) -> void:
	_heap.append(timer)
	_sift_up(_heap.size() - 1)


func _pop() -> Dictionary:
	var top := _heap[0]
	var last: Dictionary = _heap.pop_back()
	if not _heap.is_empty():
		_heap[0] = last
		_sift_down(0)
	return top


func _sift_up(i: int) -> int:
	while i > 0:
		var parent := (i - 1) / 2
		if _timer_less(_heap[i], _heap[parent]):
			var tmp := _heap[i]
			_heap[i] = _heap[parent]
			_heap[parent] = tmp
			i = parent
		else:
			break
	return i


func _sift_down(i: int) -> void:
	var n := _heap.size()
	while true:
		var smallest := i
		var l := 2 * i + 1
		var r := 2 * i + 2
		if l < n and _timer_less(_heap[l], _heap[smallest]):
			smallest = l
		if r < n and _timer_less(_heap[r], _heap[smallest]):
			smallest = r
		if smallest == i:
			return
		var tmp := _heap[i]
		_heap[i] = _heap[smallest]
		_heap[smallest] = tmp
		i = smallest
