extends SimTest
## Doc 10 §2.15 — the cosmetic civilian traffic feed published as doc 11 §5's
## `vehicle_spawned` / `traffic_snapshot` / `vehicle_despawned` stream.
##
## The three properties that matter to a renderer agent: the stream is
## DETERMINISTIC, it is CAPPED, and vehicles DESPAWN ON ARRIVAL. The fourth,
## which matters to everyone else, is that it has ZERO simulation authority.
##
## Motion rides ONE packed `traffic_snapshot` event per tick since doc 91 D-10's
## bus diet; the determinism digest below therefore walks the packed columns
## rather than a per-vehicle event, and asserts the same values it always did.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


## A lattice big enough to carry real traffic, jammed to rush-hour congestion.
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


## Run the feed for `minutes` game-minutes at 4 Hz and return the event stream.
func _run_feed(net: RoadNetwork, minutes: int, hour: float = 17.6) -> Array:
	var events: Array = []
	for minute in minutes:
		net.feed.rebalance()
		for tick in 4:
			net.feed.advance(0.25, hour)
			net.feed.emit_states()
		events.append_array(net.feed.drain_events())
	return events


func _digest(events: Array) -> String:
	var parts := PackedStringArray()
	for event in events:
		match event["type"]:
			&"vehicle_spawned":
				parts.append("S%d:%s:%d" % [int(event["id"]), String(event["kind"]),
						int(event["edge_id"])])
			&"vehicle_despawned":
				parts.append("D%d:%s" % [int(event["id"]), String(event["reason"])])
			TrafficSnapshot.VEHICLE_EVENT:
				# Every row, in the packed order — the digest is deliberately
				# stricter than the old one, which could not see the ORDER of
				# the columns because each vehicle carried its own event.
				for i in TrafficSnapshot.vehicle_count(event):
					var row := TrafficSnapshot.vehicle_at(event, i)
					var pos: Vector3 = row["pos"]
					parts.append("U%d:%.4f,%.4f:%.4f:%.4f" % [int(row["id"]), pos.x, pos.z,
							float(row["heading"]), float(row["speed"])])
	return "|".join(parts)


# ------------------------------------------------------------------ determinism

func test_vehicle_event_stream_is_deterministic() -> void:
	var first := _run_feed(_busy_network(1337), 12)
	var second := _run_feed(_busy_network(1337), 12)
	assert_true(_digest(first).length() > 2000,
			"the feed actually produced a stream (%d events, %d digest chars)"
			% [first.size(), _digest(first).length()])
	assert_eq(_digest(first), _digest(second),
			"two runs of the same seed are byte-identical, down to position and heading")
	var different := _run_feed(_busy_network(4242), 12)
	assert_ne(_digest(different), _digest(first), "a different seed gives a different city")


func test_feed_uses_only_the_reserved_traffic_stream() -> void:
	# Constitution §5 / report 98 C-45: `traffic` is reserved for exactly this,
	# so enabling the cosmetic feed can never perturb another system's sequence.
	var offenders: Array = []
	_scan_for_traffic_stream("res://sim", offenders)
	assert_eq(str(offenders), '["res://sim/roads/traffic_feed.gd"]',
			"only the cosmetic feed draws from the traffic stream")


func _scan_for_traffic_stream(path: String, offenders: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path + "/" + entry
		if dir.current_is_dir():
			_scan_for_traffic_stream(full, offenders)
		elif entry.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(full)
			if text.contains('stream("traffic")'):
				offenders.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	offenders.sort()


# ------------------------------------------------------------------------ caps

func test_global_cap_by_graphics_preset() -> void:
	var tun := RoadsTestRig.tunables()
	assert_eq(tun.civ_cap("performance"), 40)
	assert_eq(tun.civ_cap("balanced"), 90)
	assert_eq(tun.civ_cap("high"), 160)
	for preset in ["performance", "balanced", "high"]:
		var net := _busy_network(99, 2.0)  # gridlock: demand far above any cap
		net.feed.preset = preset
		_run_feed(net, 6)
		assert_true(net.feed.vehicle_count() <= tun.civ_cap(preset),
				"%s holds at most %d cars (%d)"
				% [preset, tun.civ_cap(preset), net.feed.vehicle_count()])
		assert_true(net.feed.vehicle_count() > 0, "%s still shows traffic" % preset)


func test_per_edge_cap() -> void:
	var net := _busy_network(7, 2.0)
	_run_feed(net, 8)
	var per_edge: Dictionary = {}
	for vehicle_id in net.feed.vehicle_ids_sorted():
		var edge_id := int(net.feed.vehicle(vehicle_id)["edge_id"])
		per_edge[edge_id] = int(per_edge.get(edge_id, 0)) + 1
	for edge_id in per_edge:
		assert_true(int(per_edge[edge_id]) <= net.tun.civ_max_cars_per_edge,
				"edge %d carries %d cars (max %d)"
				% [edge_id, int(per_edge[edge_id]), net.tun.civ_max_cars_per_edge])


func test_density_follows_congestion() -> void:
	# The population tracks c_e: an empty city at 02:00 vs a jam at 17:40.
	var quiet := _busy_network(21, 0.10)
	_run_feed(quiet, 8, 2.0)
	var busy := _busy_network(21, 1.60)
	_run_feed(busy, 8, 17.6)
	assert_true(busy.feed.vehicle_count() > quiet.feed.vehicle_count() * 3,
			"a jam shows far more cars than an empty night (%d vs %d)"
			% [busy.feed.vehicle_count(), quiet.feed.vehicle_count()])


# ------------------------------------------------------------ despawn on arrival

func test_vehicles_despawn_on_arrival() -> void:
	var net := _busy_network(5150, 1.0)
	var events := _run_feed(net, 40)
	var reasons: Dictionary = {}
	var spawned := 0
	for event in events:
		if event["type"] == &"vehicle_spawned":
			spawned += 1
		elif event["type"] == &"vehicle_despawned":
			reasons[String(event["reason"])] = int(reasons.get(String(event["reason"]), 0)) + 1
	assert_true(spawned > 0, "cars spawned")
	assert_true(int(reasons.get("arrived", 0)) > 0,
			"cars complete their trip and despawn (%s)" % str(reasons))
	# Every vehicle's trip is finite: hops are drawn from the authored band.
	for vehicle_id in net.feed.vehicle_ids_sorted():
		var hops := int(net.feed.vehicle(vehicle_id)["hops_remaining"])
		assert_true(hops >= 0 and hops <= net.tun.civ_trip_hops_max,
				"trip length stays inside [0, %d]" % net.tun.civ_trip_hops_max)


func test_every_spawn_is_matched_by_a_despawn_or_a_live_vehicle() -> void:
	var net := _busy_network(31, 1.4)
	var events := _run_feed(net, 25)
	var live: Dictionary = {}
	for event in events:
		match event["type"]:
			&"vehicle_spawned":
				assert_false(live.has(int(event["id"])), "ids are never reused while live")
				live[int(event["id"])] = true
			&"vehicle_despawned":
				assert_true(live.has(int(event["id"])), "despawn refers to a live vehicle")
				live.erase(int(event["id"]))
			TrafficSnapshot.VEHICLE_EVENT:
				for i in TrafficSnapshot.vehicle_count(event):
					assert_true(live.has(int((event[TrafficSnapshot.KEY_IDS]
							as PackedInt32Array)[i])),
							"no pose row for a vehicle that is not on screen")
	assert_eq(live.size(), net.feed.vehicle_count(),
			"the renderer's bookkeeping matches the sim's exactly")


func test_vehicles_leave_hard_blocked_edges() -> void:
	var net := _busy_network(11, 1.5)
	_run_feed(net, 6)
	assert_true(net.feed.vehicle_count() > 0)
	# Flood every edge deep: nothing may keep driving. Advance WITHOUT a
	# rebalance first, so the despawn is attributed to the block itself rather
	# than to the density target collapsing to zero.
	for edge_id in net.graph.edge_ids_sorted():
		net.graph.edge(edge_id)["closure_cause"] = "flood_deep"
	net.feed.drain_events()
	net.feed.advance(0.25, 17.6)
	var blocked := 0
	for event in net.feed.drain_events():
		if event["type"] == &"vehicle_despawned" and String(event["reason"]) == "blocked":
			blocked += 1
	assert_true(blocked > 0, "cars caught by a hard block despawn")
	assert_eq(net.feed.vehicle_count(), 0, "every one of them, in a single step")
	_run_feed(net, 2)
	assert_eq(net.feed.vehicle_count(), 0, "and none respawn onto a flooded edge")


# ------------------------------------------------- doc 11 §5's consumption list

func test_traffic_snapshot_shape_matches_doc11() -> void:
	var net := _busy_network(77, 1.2)
	var events := _run_feed(net, 4)
	var checked_spawn := 0
	var checked_rows := 0
	for event in events:
		match event["type"]:
			&"vehicle_spawned":
				for key in ["id", "kind", "pos", "heading", "speed", "edge_id",
						"siren", "lightbar", "headlights"]:
					assert_true(event.has(key), "vehicle_spawned carries %s" % key)
				assert_true(event["pos"] is Vector3, "world-space metres on the XZ plane")
				checked_spawn += 1
			TrafficSnapshot.VEHICLE_EVENT:
				# The columns are the contract. Arity first: a pose buffer that
				# is not exactly `count * POSE_STRIDE` long is a renderer reading
				# someone else's vehicle.
				var count := TrafficSnapshot.vehicle_count(event)
				assert_eq((event[TrafficSnapshot.KEY_IDS] as PackedInt32Array).size(), count,
						"ids column")
				assert_eq((event[TrafficSnapshot.KEY_EDGES] as PackedInt32Array).size(), count,
						"edge_ids column")
				assert_eq((event[TrafficSnapshot.KEY_KINDS] as PackedByteArray).size(), count,
						"kinds column")
				assert_eq((event[TrafficSnapshot.KEY_FLAGS] as PackedByteArray).size(), count,
						"flags column")
				assert_eq((event[TrafficSnapshot.KEY_POSE] as PackedFloat32Array).size(),
						count * TrafficSnapshot.POSE_STRIDE, "pose buffer arity")
				var previous := -1
				for i in count:
					var row := TrafficSnapshot.vehicle_at(event, i)
					# Report 98 C-67: speed and heading are FIRST-CLASS fields,
					# not derived — doc 11's Hermite blend needs a velocity term.
					for key in ["id", "pos", "heading", "speed", "siren", "lightbar"]:
						assert_true(row.has(key), "unpacked row carries %s" % key)
					assert_false(bool(row["siren"]), "civilians never run a siren")
					assert_false(bool(row["lightbar"]), "or a lightbar")
					assert_true(float(row["speed"]) > 0.0, "and are always moving")
					assert_true(int(row["id"]) > previous,
							"rows are in ascending id — the feed's canonical order")
					previous = int(row["id"])
					checked_rows += 1
	assert_true(checked_spawn > 0 and checked_rows > 0)


## Doc 91 D-10, the measurement the diet exists for: motion is ONE event per
## tick regardless of how many cars are on the road. Before the diet this run
## put one event on the bus per vehicle per tick.
func test_bus_volume_is_one_motion_event_per_tick() -> void:
	var net := _busy_network(1337, 1.6)
	net.feed.preset = "high"          # the widest cap, so the saving is visible
	var minutes := 12
	var events := _run_feed(net, minutes)
	var ticks := minutes * 4
	var motion := 0
	var rows := 0
	var identity := 0
	for event in events:
		if event["type"] == TrafficSnapshot.VEHICLE_EVENT:
			motion += 1
			rows += TrafficSnapshot.vehicle_count(event)
		else:
			identity += 1
	assert_true(motion > 0 and motion <= ticks,
			"at most one motion event per tick (%d over %d ticks)" % [motion, ticks])
	assert_true(rows > motion * 20,
			"...carrying real traffic: %d poses in %d events" % [rows, motion])
	# The old shape would have put `rows` events on the bus; the new one puts
	# `motion`. Anything under a 20x collapse means the feed has stopped filling.
	assert_true(rows >= motion * 20,
			"the collapse is at least 20x (%d poses -> %d events)" % [rows, motion])
	assert_true(identity < rows / 4,
			"spawn/despawn stay individual but are a minority of the stream (%d vs %d)"
			% [identity, rows])


func test_headlights_follow_the_clock() -> void:
	var night := _busy_network(3, 1.0)
	_run_feed(night, 3, 21.0)
	assert_true(night.feed.headlights, "headlights on at 21:00")
	var day := _busy_network(3, 1.0)
	_run_feed(day, 3, 12.0)
	assert_false(day.feed.headlights, "off at midday")
	var dawn := _busy_network(3, 1.0)
	_run_feed(dawn, 3, 5.0)
	assert_true(dawn.feed.headlights, "still on at 05:00, off from 06:00")


func test_speed_responds_to_congestion_and_condition() -> void:
	var tun := RoadsTestRig.tunables()
	var free := _busy_network(9, 0.0)
	var jammed := _busy_network(9, 2.0)
	_run_feed(free, 4)
	_run_feed(jammed, 4)
	# v = 34 x class_mult x (1 - 0.325c) x jitter; at c=2 that is 0.35x.
	assert_almost_eq(1.0 - tun.civ_speed_congestion_coeff * 2.0, 0.35, 1e-9,
			"gridlock crawls at 0.35x")
	var fast := 0.0
	for vehicle_id in free.feed.vehicle_ids_sorted():
		fast = maxf(fast, float(free.feed.vehicle(vehicle_id)["speed_mpgm"]))
	var slow := 0.0
	var count := 0
	for vehicle_id in jammed.feed.vehicle_ids_sorted():
		slow += float(jammed.feed.vehicle(vehicle_id)["speed_mpgm"])
		count += 1
	if count > 0 and fast > 0.0:
		assert_true(slow / float(count) < fast, "jammed traffic is slower than free flow")


# ------------------------------------------------------- zero simulation authority

func test_feed_has_zero_simulation_authority() -> void:
	# Turning the cars off must change NOTHING except the picture.
	var with_cars := _busy_network(1234, 1.0)
	var without := _busy_network(1234, 1.0)
	without.feed.enabled = false
	var prof := RouteProfile.emergency(32.0, 0)
	var clock := GameClock.new()
	for tick in 240:
		clock.tick_index = tick
		var ctx := RoadsTestRig.context(tick, 17.6)
		for net in [with_cars, without]:
			net.step(ctx)
			if tick % 4 == 0:
				net.minute_pass(ctx)
	assert_true(with_cars.feed.vehicle_count() > 0, "one of them really did run cars")
	assert_eq(without.feed.vehicle_count(), 0)
	for edge_id in with_cars.graph.edge_ids_sorted():
		assert_almost_eq(with_cars.congestion.congestion_of(edge_id),
				without.congestion.congestion_of(edge_id), 0.0,
				"congestion is bit-identical with and without the cosmetic layer")
	for i in 8:
		var a := Vector2i(i * 6, 0)
		var b := Vector2i(54 - i * 6, 54)
		assert_almost_eq(with_cars.route_minutes(a, b, prof),
				without.route_minutes(a, b, prof), 0.0,
				"and so is every route quote")


func test_feed_survives_a_save() -> void:
	# AMENDED (doc 93 §E2): §2.15's "vehicles are never saved" predates the
	# feed living sim-side on the PERSISTED `traffic` stream. An empty
	# post-load feed re-draws a different number of times than the live run
	# and the stream state diverges forever — so the roster rides the save
	# and the loaded feed continues draw-for-draw where the live one was.
	var net := _busy_network(88, 1.2)
	_run_feed(net, 5)
	assert_true(net.feed.vehicle_count() > 0)
	var section := net.save_section()
	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1))
	reloaded.load_section(section)
	assert_eq(reloaded.feed.vehicle_count(), net.feed.vehicle_count(),
			"the roster survives the reload")
	assert_eq(reloaded.feed.vehicle_ids_sorted(), net.feed.vehicle_ids_sorted(),
			"same vehicles, same ids")
	assert_eq(reloaded.feed.next_vehicle_id, net.feed.next_vehicle_id,
			"the id high-water mark survives, so ids never recycle")


func test_no_cosmetic_traffic_in_coarse_steps() -> void:
	# Offline catch-up runs no cosmetic traffic: nobody is watching.
	var net := _busy_network(55, 1.2)
	var ctx := RoadsTestRig.context(0, 17.6, TimeContext.Mode.COARSE)
	ctx.dt_game_seconds = 3600
	net.step(ctx)
	net.full_pass(ctx)
	var vehicle_events := 0
	for event in net.drain_events():
		if String(event["type"]).begins_with("vehicle_"):
			vehicle_events += 1
	assert_eq(vehicle_events, 0, "a coarse hour emits no vehicle events at all")
	assert_eq(net.feed.vehicle_count(), 0)


func test_traffic_snapshot_for_the_renderer() -> void:
	var net := _busy_network(66, 0.8)
	net.add_closure([Vector2i(24, 12)], "accident_minor", 0.6, 90)
	net.minute_pass(RoadsTestRig.context(4, 17.6))
	var snapshot := net.snapshot
	assert_eq(snapshot.visible_edges.size(), net.graph.edge_count())
	assert_eq(snapshot.active_closures.size(), 1)
	var found_band := false
	for view in snapshot.visible_edges:
		for key in ["edge_id", "tiles", "congestion", "band", "closure_cause",
				"condition_tier", "blocked_mask", "node_a_dark", "node_b_dark", "density"]:
			assert_true(view.has(key), "TrafficSnapshot carries %s" % key)
		if view["band"] == &"heavy" or view["band"] == &"severe":
			found_band = true
		assert_true(float(view["density"]) >= 0.0 and float(view["density"]) <= 1.0,
				"density is the [0,1] value doc 11 §2.12 asks for")
	assert_true(found_band, "the overlay bands actually discriminate")
	assert_eq(RoadCosts.overlay_band(0.10), &"clear")
	assert_eq(RoadCosts.overlay_band(0.30), &"light")
	assert_eq(RoadCosts.overlay_band(0.60), &"heavy")
	assert_eq(RoadCosts.overlay_band(0.80), &"severe")
	assert_eq(RoadCosts.overlay_band(1.50), &"gridlock")
