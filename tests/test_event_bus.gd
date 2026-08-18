extends SimTest


func test_emit_and_drain_in_order() -> void:
	var bus := SimEventBus.new()
	bus.emit(&"power_outage", {"district": 3})
	bus.emit(&"fire_started", {"building": 17})
	assert_eq(bus.pending_count(), 2)
	var events := bus.drain()
	assert_eq(events.size(), 2)
	assert_eq(events[0]["type"], &"power_outage")
	assert_eq(events[0]["district"], 3)
	assert_eq(events[1]["type"], &"fire_started")
	assert_eq(events[1]["building"], 17)


func test_drain_empties_bus() -> void:
	var bus := SimEventBus.new()
	bus.emit(&"tick")
	bus.drain()
	assert_eq(bus.pending_count(), 0)
	assert_eq(bus.drain().size(), 0)


func test_emit_does_not_mutate_caller_dict() -> void:
	var bus := SimEventBus.new()
	var payload := {"x": 1}
	bus.emit(&"test", payload)
	assert_false(payload.has("type"), "caller's dictionary must not be mutated")
