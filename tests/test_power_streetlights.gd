extends SimTest
## Doc 04 §5.2's `StreetlightsChanged(block_id, lit)` — the per-block streetlight
## circuit doc 11 §2.10 draws and report 93 §D logged as the last missing wire
## between the grid and the street.
##
## What these guard, in order: that the event exists at all and carries doc 11's
## exact payload; that it follows the CIRCUIT rather than
## `block_dark_fractions`' ≥60 % building quorum; that only transitions emit;
## that the stream is sorted and identical on the coarse path; and that a
## deserialized grid re-announces a block that came back dark instead of
## silently assuming the renderer already knows.


func _two_block_grid() -> PowerGrid:
	# One substation, a north and a south feeder, three blocks' worth of
	# transformers. Same geometry as test_power_grid's subtree-exactness rig.
	var grid := PowerGrid.new()
	grid.add_component("plant", &"plant_gas", {"level": 1})
	grid.add_component("s_1", &"substation", {"level": 1})
	grid.add_component("f_north", &"feeder", {"conductor_class": 1, "parent": "s_1"})
	grid.add_component("f_south", &"feeder", {"conductor_class": 1, "parent": "s_1"})
	grid.add_component("t_n1", &"transformer",
			{"level": 1, "parent": "f_north", "tile": Vector2i(5, 5)})
	grid.add_component("t_s1", &"transformer",
			{"level": 1, "parent": "f_south", "tile": Vector2i(5, 40)})
	grid.add_component("t_s2", &"transformer",
			{"level": 1, "parent": "f_south", "tile": Vector2i(10, 40)})
	grid.attach_building("north_b", Vector2i(5, 5), &"STANDARD", "block_n")
	grid.attach_building("south_b1", Vector2i(5, 40), &"STANDARD", "block_s")
	grid.attach_building("south_b2", Vector2i(10, 40), &"STANDARD", "block_s")
	return grid


func _tick(grid: PowerGrid, n: int = 1, coarse: bool = false) -> void:
	var rng := RngStreams.new(11)
	var demands := {"north_b": 20.0, "south_b1": 20.0, "south_b2": 20.0}
	for i in n:
		if coarse:
			grid.tick(3600, demands, {}, {"t_ambient_c": 22.0}, rng)
		else:
			grid.tick(15, demands, {}, {"t_ambient_c": 22.0}, rng)


func _streetlight_events(grid: PowerGrid) -> Array:
	var out: Array = []
	for event in grid.drain_events():
		if StringName(String(event["type"])) == &"StreetlightsChanged":
			out.append(event)
	return out


func test_a_healthy_grid_never_announces_anything() -> void:
	var grid := _two_block_grid()
	_tick(grid, 4)
	assert_eq(_streetlight_events(grid).size(), 0,
			"lit is the assumed state; a boot with power emits no traffic")
	assert_true(grid.streetlights_lit("block_n"))
	assert_true(grid.streetlights_lit("block_s"))


func test_opening_a_feeder_darkens_exactly_its_blocks() -> void:
	var grid := _two_block_grid()
	_tick(grid, 3)
	grid.drain_events()
	grid.force_open("f_south")
	_tick(grid, 1)
	var events := _streetlight_events(grid)
	assert_eq(events.size(), 1, "one block flipped, one event")
	assert_eq(String(events[0]["block_id"]), "block_s", "the block on the open feeder")
	assert_false(bool(events[0]["lit"]), "its streets go out")
	assert_false(grid.streetlights_lit("block_s"))
	assert_true(grid.streetlights_lit("block_n"), "the north subtree is untouched")

	# And back: closing the feeder relights the same block, once.
	grid.force_close("f_south")
	_tick(grid, 1)
	var back := _streetlight_events(grid)
	assert_eq(back.size(), 1, "one relight event")
	assert_eq(String(back[0]["block_id"]), "block_s")
	assert_true(bool(back[0]["lit"]))


func test_only_transitions_emit() -> void:
	var grid := _two_block_grid()
	grid.force_open("f_south")
	_tick(grid, 1)
	assert_eq(_streetlight_events(grid).size(), 1, "the flip")
	_tick(grid, 20)
	assert_eq(_streetlight_events(grid).size(), 0,
			"twenty ticks of the same dark block emit nothing")


func test_follows_the_circuit_not_the_block_dark_quorum() -> void:
	# The distinction that makes this a separate event: `block_dark_fractions`
	# calls a block dark at ≥60 % weighted DARK buildings, and its hysteresis
	# needs 20 game-seconds of sustained deficit. Streetlights go out with the
	# transformer, on the same tick — one tick after the feeder opens the
	# streets are already dark while the buildings have not even been called
	# DARK yet.
	var grid := _two_block_grid()
	_tick(grid, 3)
	grid.drain_events()
	grid.force_open("f_south")
	_tick(grid, 1)
	assert_false(grid.streetlights_lit("block_s"), "streets are out immediately")
	var weights := {"north_b": 10.0, "south_b1": 10.0, "south_b2": 10.0}
	var fractions := grid.block_dark_fractions(weights)
	assert_false(bool(fractions["block_s"]["dark"]),
			"the buildings have not yet sustained DARK — the two answers differ, "
			+ "and that is the point")


func test_stream_is_sorted_and_mode_invariant() -> void:
	# Two blocks flip on the same tick: the emission order is sorted by block
	# id, and the coarse path produces the same stream as the fine path
	# (report 98 E2 per-system mode-invariance).
	var fine := _two_block_grid()
	_tick(fine, 3)
	fine.drain_events()
	fine.force_open("f_north")
	fine.force_open("f_south")
	_tick(fine, 1)
	var fine_events := _streetlight_events(fine)
	assert_eq(fine_events.size(), 2, "both blocks flipped")
	assert_eq(String(fine_events[0]["block_id"]), "block_n", "sorted: block_n first")
	assert_eq(String(fine_events[1]["block_id"]), "block_s")

	var coarse := _two_block_grid()
	_tick(coarse, 3, true)
	coarse.drain_events()
	coarse.force_open("f_north")
	coarse.force_open("f_south")
	_tick(coarse, 1, true)
	var coarse_events := _streetlight_events(coarse)
	assert_eq(coarse_events.size(), fine_events.size(), "same event count")
	for i in coarse_events.size():
		assert_eq(String(coarse_events[i]["block_id"]),
				String(fine_events[i]["block_id"]), "same order")
		assert_eq(bool(coarse_events[i]["lit"]), bool(fine_events[i]["lit"]))


func test_a_loaded_save_re_announces_a_dark_block() -> void:
	# The state is derived, so it is not in the save section (save identity is
	# exact — nothing was added to `serialize`). What the load must NOT do is
	# leave the renderer believing a dark block is lit: the first energization
	# pass after `deserialize` re-emits it.
	var grid := _two_block_grid()
	grid.force_open("f_south")
	_tick(grid, 2)
	grid.drain_events()

	var blob := grid.serialize()
	assert_false(blob.has("block_streetlights"),
			"derived state never reaches the save section")
	var loaded := PowerGrid.new()
	loaded.deserialize(blob)
	_tick(loaded, 1)
	var events := _streetlight_events(loaded)
	assert_eq(events.size(), 1, "the dark block re-announces itself once")
	assert_eq(String(events[0]["block_id"]), "block_s")
	assert_false(bool(events[0]["lit"]))
	_tick(loaded, 3)
	assert_eq(_streetlight_events(loaded).size(), 0, "and then goes quiet again")


func test_payload_matches_the_renderer_contract() -> void:
	# doc 11 §4's `RenderStateModel.apply_event` reads exactly these two keys.
	var grid := _two_block_grid()
	_tick(grid, 2)
	grid.drain_events()
	grid.force_open("f_south")
	_tick(grid, 1)
	var event: Dictionary = _streetlight_events(grid)[0]
	assert_true(event.has("block_id"), "block_id")
	assert_true(event.has("lit"), "lit")
	assert_eq(typeof(event["lit"]), TYPE_BOOL, "lit is a bool, not a ramp")
	assert_eq(StringName(String(event["type"])), &"StreetlightsChanged")
