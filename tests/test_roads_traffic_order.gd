extends SimTest
## `TrafficFeed`'s per-edge index is ORDER-CANONICAL (doc 10's Wave-12 open q5).
##
## The fragility this file closes was never a live bug and that is the point.
## `_by_edge` was insertion-ordered, and a shipped city produces two different
## insertion histories for the same feed:
##
##   * LIVE — `_spawn` appends to the edge a car starts on, and `_hop` appends it
##     again to every edge it moves onto, so a per-edge list is in VISIT order and
##     the key order is first-touch order;
##   * RESTORED — `deserialize` walks the saved roster in ascending vehicle id, so
##     a per-edge list is in ID order and the key order is first appearance in
##     that walk.
##
## Nothing diverged, because the one consumer (`rebalance`) copied each list,
## sorted it, and iterated `_sorted_keys()`. That is a defence every future reader
## of the container has to remember, and the first one to forget it breaks
## save→load→advance identity in a way that only reproduces after a hop.
##
## So the tests below assert over the RAW containers — no sorting on the way in.
## `test_the_raw_per_edge_lists_are_identical_live_and_restored` is precisely the
## assertion an unsorted future consumer would need, and it is the one that fails
## on the pre-Wave-14 feed.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


## The same jammed lattice `tests/test_roads_traffic.gd` uses — the only network
## in the suite that produces enough hops for the two orders to disagree.
func _busy_network(seed_value: int = 1337, congestion: float = 1.2) -> RoadNetwork:
	var tiles: Dictionary = {}
	for i in range(0, 60, 6):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, i), Vector2i(54, i),
				AVENUE if i % 18 == 0 else STREET))
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(i, 0), Vector2i(i, 54),
				AVENUE if i % 18 == 0 else STREET), false)
	var net := RoadsTestRig.network_with(tiles, seed_value)
	for edge_id in net.graph.edge_ids_sorted():
		net.graph.edge(edge_id)["congestion"] = congestion
	return net


func _run_feed(net: RoadNetwork, minutes: int, hour: float = 17.6) -> void:
	for minute in minutes:
		net.feed.rebalance()
		for tick in 4:
			net.feed.advance(0.25, hour)
			net.feed.emit_states()
		net.feed.drain_events()


## The index exactly as stored: keys in container order, each list in container
## order. No `sort()` anywhere — that is what makes this an oracle rather than a
## restatement of what the consumer already does.
func _raw_index(feed: TrafficFeed) -> String:
	var parts := PackedStringArray()
	for edge_id in feed.edges_with_vehicles():
		var ids := PackedStringArray()
		for vehicle_id in feed.vehicles_on_edge(int(edge_id)):
			ids.append(str(int(vehicle_id)))
		parts.append("%d:%s" % [int(edge_id), ",".join(ids)])
	return "|".join(parts)


## A saved-and-reloaded twin. The RNG rides along because the feed draws from the
## PERSISTED `traffic` stream (doc 10 §2.15 as built): a clone seeded afresh would
## re-draw from a different position and diverge for that reason instead of the
## one under test. `CitySim` restores the stream from its own save section, which
## is the section a `RoadNetwork`-only fixture does not have.
func _reloaded(net: RoadNetwork) -> RoadNetwork:
	var section := net.save_section()
	var rng := RngStreams.new(1)
	rng.deserialize(net.rng.serialize())
	var clone := RoadNetwork.new(TileGrid.new(), net.tun, rng)
	clone.load_section(section)
	return clone


# ------------------------------------------------------ the fragility, closed

func test_the_raw_per_edge_lists_are_identical_live_and_restored() -> void:
	var net := _busy_network(88, 1.2)
	_run_feed(net, 6)
	assert_true(net.feed.vehicle_count() > 20,
			"the fixture actually filled up (%d vehicles)" % net.feed.vehicle_count())
	var hopped := 0
	for edge_id in net.feed.edges_with_vehicles():
		hopped += net.feed.vehicles_on_edge(int(edge_id)).size()
	assert_eq(hopped, net.feed.vehicle_count(), "every live vehicle is indexed exactly once")
	assert_eq(_raw_index(_reloaded(net).feed), _raw_index(net.feed),
			"the index is byte-identical without anyone sorting it")


func test_every_stored_list_is_ascending_after_hops() -> void:
	# The half a restore could never break: a LIVE feed's lists. Before Wave 14
	# `_hop` appended, so a car that moved onto an occupied edge landed after a
	# higher id and this assertion failed on the live arm alone.
	var net := _busy_network(1337, 1.4)
	_run_feed(net, 8)
	var checked := 0
	for edge_id in net.feed.edges_with_vehicles():
		var ids: Array = net.feed.vehicles_on_edge(int(edge_id))
		for i in range(1, ids.size()):
			assert_true(int(ids[i - 1]) < int(ids[i]),
					"edge %d holds %s in ascending id order" % [int(edge_id), str(ids)])
			checked += 1
	assert_true(checked > 0, "at least one edge carried two cars at once (%d pairs)" % checked)


func test_the_key_vector_mirrors_the_dictionary_exactly() -> void:
	# `_edge_keys` is a maintained parallel index, which is its own fragility if
	# it can drift. It cannot: this walks a feed through spawns, hops, despawns
	# and a reset, and asserts the invariant after each phase.
	var net := _busy_network(4242, 1.1)
	_assert_keys_agree(net.feed, "empty")
	_run_feed(net, 4)
	_assert_keys_agree(net.feed, "after spawns and hops")
	net.feed.enabled = false
	net.feed.rebalance()          # `_shrink_to(0)` — every despawn path at once
	_assert_keys_agree(net.feed, "after a full drain")
	assert_eq(net.feed.edges_with_vehicles().size(), 0, "and the index emptied with it")
	net.feed.enabled = true
	net.feed.rebalance()
	_assert_keys_agree(net.feed, "after refilling")
	net.feed.reset()
	_assert_keys_agree(net.feed, "after reset")
	assert_eq(net.feed.edges_with_vehicles().size(), 0)


func _assert_keys_agree(feed: TrafficFeed, phase: String) -> void:
	# Reads the private container on purpose: the whole claim is that the public
	# seam and the raw Dictionary carry the same keys in the same order, and a
	# test that only asked the seam could not see a drift.
	var keys: Array = feed._by_edge.keys()
	keys.sort()
	var seam := feed.edges_with_vehicles()
	assert_eq(seam.size(), keys.size(), "%s: same number of occupied edges" % phase)
	var previous := -1
	for i in seam.size():
		assert_eq(int(seam[i]), int(keys[i]), "%s: key %d matches" % [phase, i])
		assert_true(int(seam[i]) > previous, "%s: strictly ascending" % phase)
		previous = int(seam[i])
		assert_false(feed.vehicles_on_edge(int(seam[i])).is_empty(),
				"%s: an emptied edge is erased, never left as an empty list" % phase)


func test_a_restored_feed_keeps_stepping_identically() -> void:
	# The consequence the ordering exists for, stated end to end: the live feed
	# and the restored one produce the same index after the SAME further work.
	var net := _busy_network(777, 1.3)
	_run_feed(net, 5)
	var clone := _reloaded(net)
	_run_feed(net, 3)
	_run_feed(clone, 3)
	assert_eq(_raw_index(clone.feed), _raw_index(net.feed),
			"three more game-minutes, same index, still unsorted by anybody")
	assert_eq(clone.feed.vehicle_ids_sorted(), net.feed.vehicle_ids_sorted())
