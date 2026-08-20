extends SimTest
## Doc 07 §2.4 / doc 11 §2.9b — STANDING WATER, drawn (defect A91-D-26).
##
## The particles-and-pixels half of a render layer is not testable headless and
## is not where the bugs live. What is testable, and what these guard, is every
## claim `game/render/flood_view.gd` makes about the picture:
##
##   * it consumes doc 07's `flood_level_changed` payload **verbatim**, which is
##     the exact thing nothing in the tree did before this branch;
##   * `water01` is doc 07's own `flood_saturation` — `depth_mm / 350` — with
##     the 350 read out of `data/weather.json` and not restated;
##   * the dark-wet memory outlives the water, which is the difference between
##     "the water went away" and "there was a flood here";
##   * the drawn set is the flooded block's ROAD tiles, in a deterministic
##     order, and the buffer two identical runs produce is identical float for
##     float;
##   * a city LOADED mid-flood shows the flood on its first frame, off the
##     persisted field and with no event at all;
##   * dry costs nothing — no instances, no draw call, node hidden.

const RENDER_JSON := "res://data/render.json"
const WEATHER_JSON := "res://data/weather.json"


func _view() -> FloodView:
	var view := FloodView.new()
	view.setup(StarterCityLoader.read_json(RENDER_JSON))
	return view


## A 2x2-block toy grid with a road cross through blocks B0,0 and B1,0, so the
## per-block cell keys have real tiles under them and the two blocks can be
## driven to different depths.
func _grid() -> TileGrid:
	var grid := TileGrid.new()
	for x in 32:
		grid.set_flag(x, 4, TileGrid.FLAG_ROAD)
	for z in 16:
		grid.set_flag(6, z, TileGrid.FLAG_ROAD)
	return grid


func _flooded(cell: String, depth: float, band: String) -> Dictionary:
	return {"type": &"flood_level_changed", "cell": cell,
			"is_block": cell.begins_with("B"), "depth_mm": depth, "band": band,
			"road_speed_mult": 0.45}


# ------------------------------------------------- doc 07's payload, verbatim

func test_consumes_doc_07s_event_and_nothing_else() -> void:
	var view := _view()
	view.rebuild(_grid())
	assert_true(view.apply_event(_flooded("B0,0", 175.0, "standing_water")),
			"flood_level_changed is claimed")
	assert_false(view.apply_event({"type": &"weather_changed", "precip01": 1.0}),
			"the rain integrator is WeatherFX's and stays there")
	assert_false(view.apply_event({"type": &"road_closed_flood", "cell": "B0,0"}),
			"the closure is doc 10's story, not this layer's")
	assert_almost_eq(view.target01_of("B0,0"), 0.5, 1e-6,
			"175 mm / 350 mm = 0.50 — doc 07's own flood_saturation")
	view.free()


func test_the_full_depth_is_read_from_doc_07s_table_not_restated() -> void:
	var view := _view()
	var doc: Dictionary = StarterCityLoader.read_json(WEATHER_JSON)
	var thresholds: Array = (doc["flood"] as Dictionary)["thresholds"]
	var last: Dictionary = thresholds[thresholds.size() - 1]
	var impassable := float(last["depth_mm"])
	assert_almost_eq(view.full_depth_mm, impassable, 1e-9,
			"the divisor is the last row of data/weather.json's band table")
	assert_almost_eq(view.full_depth_mm, 350.0, 1e-9,
			"which is the 350 mm FloodField.flood_saturation() divides by")
	view.free()


func test_a_batch_is_drained_the_way_the_shell_drains_it() -> void:
	var view := _view()
	view.rebuild(_grid())
	assert_true(view.feed_events([{"type": &"weather_changed"},
			_flooded("B1,0", 350.0, "impassable")]), "one flood in a mixed batch")
	assert_almost_eq(view.target01_of("B1,0"), 1.0, 1e-6)
	assert_false(view.feed_events([{"type": &"weather_changed"}]),
			"a batch with no flood in it touches nothing")
	view.free()


# --------------------------------------------------------------- the easing

func test_water_rises_faster_than_it_falls() -> void:
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B0,0", 350.0, "impassable"))
	view.refresh(1.1)   # one rise tau
	var risen := view.water01_of("B0,0")
	assert_true(risen > 0.60 and risen < 0.70,
			"one tau of a 1.1 s rise is ~63%% of the way: %f" % risen)
	view.apply_event(_flooded("B0,0", 0.0, "dry"))
	view.refresh(1.1)   # the SAME wall-clock, now falling
	var fallen := risen - view.water01_of("B0,0")
	assert_true(fallen < risen * 0.63,
			"the same second buys less on the way down (2.6 s tau): %f" % fallen)
	view.free()


func test_the_dark_wet_memory_outlives_the_water() -> void:
	# The whole reason `wet01` is a second channel and not `water01` again.
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B0,0", 350.0, "impassable"))
	for i in 40:
		view.refresh(0.25)
	assert_almost_eq(view.water01_of("B0,0"), 1.0, 1e-3, "soaked")
	assert_almost_eq(view.wet01_of("B0,0"), 1.0, 1e-3, "and dark")
	view.apply_event(_flooded("B0,0", 0.0, "dry"))
	for i in 48:
		view.refresh(0.25)   # twelve seconds: 4.6 fall taus, 0.6 of a dry tau
	assert_true(view.water01_of("B0,0") < 0.02,
			"the water is gone: %f" % view.water01_of("B0,0"))
	assert_true(view.wet01_of("B0,0") > 0.5,
			"the street is still dark: %f" % view.wet01_of("B0,0"))
	assert_true(view.drawn_tiles() > 0, "and still drawn, which is the point")
	view.free()


func test_a_dry_city_costs_one_hidden_node() -> void:
	var view := _view()
	view.rebuild(_grid())
	view.refresh(0.5)
	assert_eq(view.drawn_tiles(), 0, "nothing to draw")
	assert_eq(view.draw_calls(), 0, "and nothing drawn")
	view.apply_event(_flooded("B0,0", 120.0, "standing_water"))
	view.refresh(0.5)
	assert_true(view.drawn_tiles() > 0, "water arrives")
	assert_eq(view.draw_calls(), 1, "as ONE call, whatever the tile count")
	# ...and eventually goes away again, buffer and all.
	view.apply_event(_flooded("B0,0", 0.0, "dry"))
	for i in 200:
		view.refresh(1.0)   # 200 s — ten dry taus, well past `min_visible`
	assert_eq(view.drawn_tiles(), 0, "fully dry: the buffer empties")
	assert_eq(view.draw_calls(), 0)
	view.free()


# ------------------------------------------------------- the tiles it paints

func test_it_paints_the_blocks_ROAD_tiles_and_not_the_block() -> void:
	# Doc 07 §2.4: "only road tiles ... accumulate water". A 128 m sheet over
	# the land block would put standing water through every building on it.
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B0,0", 350.0, "impassable"))
	view.refresh(0.1)
	# Block 0,0 is tiles 0..15 x 0..15: sixteen of the horizontal run plus the
	# vertical run's fifteen remaining tiles (6,4 is shared).
	assert_eq(view.drawn_tiles(), 31,
			"the 31 road tiles inside B0,0, and not its 256 tiles")
	view.free()


func test_a_cell_with_no_roads_yet_tracks_its_level_and_draws_nothing() -> void:
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B3,3", 350.0, "impassable"))
	view.refresh(0.1)
	assert_almost_eq(view.target01_of("B3,3"), 1.0, 1e-6, "the level is known")
	assert_eq(view.drawn_tiles(), 0, "and there is no street under it to wet")
	view.free()


func test_two_identical_runs_produce_an_identical_buffer() -> void:
	# The determinism claim, taken literally: same city, same events, same
	# floats. Nothing in this layer reads an RNG, a frame counter or a clock —
	# every instance is (tile position, cell depth) and nothing else.
	var a := _view()
	var b := _view()
	for view: FloodView in [a, b]:
		view.rebuild(_grid())
		view.feed_events([_flooded("B0,0", 260.0, "flooded"),
				_flooded("B1,0", 95.0, "nuisance")])
		for i in 12:
			view.refresh(0.2)
	var mirror_a := a.buffer_mirror()
	var mirror_b := b.buffer_mirror()
	assert_eq(mirror_a.size(), mirror_b.size(), "same buffer size")
	var diff := 0
	for i in mirror_a.size():
		if mirror_a[i] != mirror_b[i]:
			diff += 1
	assert_eq(diff, 0, "byte for byte, %d floats" % mirror_a.size())
	assert_true(mirror_a.size() > 0, "and it is not the empty buffer")
	a.free()
	b.free()


func test_the_instance_carries_two_channels_and_two_zeroes() -> void:
	# `.b` and `.a` are empty on purpose. A per-TILE value in this surface —
	# a hash seed was the obvious candidate, and it was tried — draws the 8 m
	# tile grid in water, because coverage has to be a function of WORLD
	# position for two adjacent tiles to read as one puddle.
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B0,0", 350.0, "impassable"))
	view.refresh(0.4)
	var mirror := view.buffer_mirror()
	var stride := FloodView.STRIDE
	var slots := view.drawn_tiles()
	assert_true(slots > 0, "something is drawn")
	for i in slots:
		assert_true(mirror[i * stride + 12] > 0.0, "slot %d carries water01" % i)
		assert_true(mirror[i * stride + 13] > 0.0, "slot %d carries wet01" % i)
		assert_eq(mirror[i * stride + 14], 0.0, "slot %d .b is reserved" % i)
		assert_eq(mirror[i * stride + 15], 0.0, "slot %d .a is reserved" % i)
	view.free()


# -------------------------------------------------------- the load path

func test_a_city_loaded_mid_flood_shows_the_flood_with_no_event() -> void:
	# Doc 07 persists the field (`WeatherSystem.serialize()` -> `flood.tiles`),
	# so the query exists and this view persists NOTHING of its own. `prime`
	# takes `FloodField.depth_mm` verbatim.
	var view := _view()
	view.rebuild(_grid())
	view.prime({"B0,0": 300.0, "B1,0": 60.0})
	view.snap()
	assert_almost_eq(view.water01_of("B0,0"), 300.0 / 350.0, 1e-6,
			"at its real depth on the first frame, not rising into it")
	assert_almost_eq(view.water01_of("B1,0"), 60.0 / 350.0, 1e-6)
	assert_true(view.drawn_tiles() > 0, "and drawn")
	assert_eq(view.draw_calls(), 1)
	view.free()


func test_priming_drains_a_cell_the_field_no_longer_mentions() -> void:
	# `FloodField` ERASES a cell whose depth clamps to zero, so "absent" means
	# "dry" and a re-prime must not leave last save's water standing.
	var view := _view()
	view.rebuild(_grid())
	view.prime({"B0,0": 300.0})
	view.snap()
	assert_true(view.water01_of("B0,0") > 0.8)
	view.prime({})
	assert_almost_eq(view.target01_of("B0,0"), 0.0, 1e-9,
			"a cell the field stopped mentioning is draining, not standing")
	view.free()


func test_a_per_tile_registration_paints_its_own_tile() -> void:
	# `FloodField.register_tile` keys "<tx>,<tz>" rather than "B<bx>,<bz>";
	# doc 09's elevation is per block today and may go finer (§9 item 8).
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("6,9", 350.0, "impassable"))
	view.refresh(0.1)
	assert_eq(view.drawn_tiles(), 1, "one tile, not a block")
	view.free()


# ------------------------------------------------------------ the cost lever

func test_the_preset_ladder_moves_the_fragment_ceiling() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json(RENDER_JSON)
	var presets: Dictionary = render_data["presets"]
	for name: String in ["performance", "balanced", "high"]:
		assert_true((presets[name] as Dictionary).has("flood_detail"),
				"%s authorises a flood rung" % name)
	var view := _view()
	view.set_preset("performance")
	assert_eq(view.detail, 0,
			"Performance renders a flat sheet: at 0.7 render scale a puddle's "
			+ "ripple was never resolvable")
	view.set_preset("high")
	assert_eq(view.detail, 2, "High takes the ripple")
	view.set_detail(5)
	assert_eq(view.detail, 2, "set_detail may lower the ceiling, never raise it")
	view.set_detail(0)
	assert_eq(view.detail, 0)
	view.free()


func test_the_buffer_is_not_re_uploaded_once_the_water_settles() -> void:
	# The layer has to be free when nothing is happening: the ripple rides
	# `sc_time` in the shader, so a settled flood costs zero CPU.
	var view := _view()
	view.rebuild(_grid())
	view.apply_event(_flooded("B0,0", 350.0, "impassable"))
	for i in 200:
		view.refresh(0.5)
	var settled := view.uploads
	for i in 60:
		view.refresh(0.5)
	assert_eq(view.uploads, settled,
			"a settled flood re-uploads nothing (%d uploads)" % settled)
	view.free()
