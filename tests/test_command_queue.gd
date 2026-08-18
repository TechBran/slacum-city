extends SimTest


func test_submit_and_drain_in_order() -> void:
	var queue := CommandQueue.new()
	var s1 := queue.submit(&"place_building", {"type": "house", "x": 3, "y": 4})
	var s2 := queue.submit(&"dispatch_unit", {"unit": 2, "incident": 9})
	assert_true(s2 > s1, "sequence numbers increase")
	assert_eq(queue.pending_count(), 2)
	var batch := queue.drain()
	assert_eq(batch.size(), 2)
	assert_eq(batch[0]["type"], &"place_building")
	assert_eq(batch[1]["type"], &"dispatch_unit")
	assert_eq(queue.pending_count(), 0)
	assert_eq(queue.drain().size(), 0)


func test_result_helpers() -> void:
	var ok := CommandQueue.ok({"building_id": 12})
	assert_true(bool(ok["ok"]))
	assert_eq(ok["payload"]["building_id"], 12)
	var fail := CommandQueue.fail(&"E_POWER_HEADROOM", {"deficit_kw": 140})
	assert_false(bool(fail["ok"]))
	assert_eq(fail["reason_code"], &"E_POWER_HEADROOM")
	assert_eq(fail["payload"]["deficit_kw"], 140)
