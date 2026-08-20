class_name SimEventBus
extends RefCounted
## Sim → outward event channel (constitution §3).
## Systems append plain event dictionaries during a tick; the app shell
## (renderer, UI, offline report builder) drains them after each advance.
## Events are data, never callbacks — the sim never calls into higher layers.

var _events: Array[Dictionary] = []

## An in-sim listener on the same stream, called SYNCHRONOUSLY inside [emit] with
## the finished event dictionary: `func(event: Dictionary) -> void`.
##
## The drain above is the app shell's — it takes the batch when it is ready, and
## it takes it *whole*. A sim system that has to count events (doc 09 §2.14's goal
## objectives are the first) cannot use it: it would be racing the shell for the
## same array, and a headless test that never drains would starve it. It also may
## not poll `_events`, because a cursor into an array somebody else empties is a
## cursor into nothing.
##
## So the bus grows one hook instead. It is deliberately a SINGLE callable rather
## than a list: one in-sim listener is the design (`CitySim` owns the fan-out to
## whatever it wires up), and a list would make emission order depend on
## registration order, which is exactly the kind of thing determinism forbids.
##
## Contract for whoever installs it: it runs inside `emit()`, so it must be
## O(1)-ish, it must not draw RNG, and it must not call `drain()`. Appending
## further events to this same bus IS allowed (they land after the one that
## caused them, which is the order a reader wants).
var observer: Callable = Callable()


func emit(event_type: StringName, data: Dictionary = {}) -> void:
	var event := data.duplicate()
	event["type"] = event_type
	_events.append(event)
	if observer.is_valid():
		observer.call(event)


func drain() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


func pending_count() -> int:
	return _events.size()
