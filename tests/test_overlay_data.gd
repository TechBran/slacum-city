extends SimTest
## Doc 12 §2.5 modes 2 and 5, on the RENDER side: the per-building overlay
## channel `RenderStateModel` maps into the packed instance state, the road
## overlay `RoadOverlayView` builds from doc 10's traffic snapshot, and the two
## shaders that read them.
##
## The contract these pin down, in one sentence: an overlay may borrow doc 11's
## two `overlay_state` bits (C-64) while it is on screen, and every building's
## own state has to come back byte for byte when it leaves.

const NORMAL := RenderStateModel.OVERLAY_NORMAL
const WARNING := RenderStateModel.OVERLAY_WARNING
const CRITICAL := RenderStateModel.OVERLAY_CRITICAL
const OFFLINE := RenderStateModel.OVERLAY_OFFLINE

const WATER := &"water"
const TRAFFIC := &"traffic"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _model() -> RenderStateModel:
	var m := RenderStateModel.new(RenderStateModel.load_config())
	m.set_hour(21.0)
	return m


func _view(id: int, extra: Dictionary = {}) -> Dictionary:
	var pos := Vector3(float(id) * 12.0, 0.0, 0.0)
	var v: Dictionary = {"id": id, "archetype_id": &"apartment", "level": 3,
			"family": "residential", "world_pos": pos, "block_id": 0,
			"chunk": Vector2i(0, 0), "transform": Transform3D(Basis.IDENTITY, pos)}
	for key: Variant in extra:
		v[key] = extra[key]
	return v


func _packed_overlay(m: RenderStateModel, id: int) -> int:
	# What the SHADER reads: the overlay field decoded back out of the packed
	# custom-data channel, not the record field it came from.
	return int(RenderStateModel.unpack_state(m.custom_data(id).b)["overlay"])


# ===========================================================================
# The per-building overlay channel (mode 2's feed path)
# ===========================================================================

func test_a_channel_only_paints_while_its_mode_is_active() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.add_building(_view(2))
	m.set_overlay_channel(WATER, {1: CRITICAL, 2: OFFLINE})
	assert_eq(_packed_overlay(m, 1), NORMAL,
			"publishing a channel does not paint anything by itself")

	m.set_overlay_mode(WATER)
	assert_eq(_packed_overlay(m, 1), CRITICAL)
	assert_eq(_packed_overlay(m, 2), OFFLINE)
	assert_eq(m.overlay_mode(), WATER)

	m.set_overlay_mode(&"none")
	assert_eq(_packed_overlay(m, 1), NORMAL, "leaving restores the building's own state")
	assert_eq(_packed_overlay(m, 2), NORMAL)


func test_a_buildings_own_state_survives_a_round_trip_through_an_overlay() -> void:
	# The one that matters: doc 11 owns `overlay_state` for damage and
	# destruction, and an overlay borrowing those two bits must not eat it.
	var m := _model()
	m.add_building(_view(1))
	m.apply_event({"type": &"building_destroyed", "building": 1})
	assert_eq(_packed_overlay(m, 1), OFFLINE, "destroyed reads OFFLINE")

	m.set_overlay_channel(WATER, {1: NORMAL})
	m.set_overlay_mode(WATER)
	assert_eq(_packed_overlay(m, 1), NORMAL, "under WATER it reads its water state")
	m.set_overlay_mode(&"none")
	assert_eq(_packed_overlay(m, 1), OFFLINE, "and it is a wreck again on the way out")


func test_damage_that_lands_during_an_overlay_is_still_there_afterwards() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.set_overlay_channel(WATER, {1: NORMAL})
	m.set_overlay_mode(WATER)
	# A fire breaks out while the player is reading the water map.
	m.apply_event({"type": &"building_damaged", "building": 1, "damage": 0.4})
	assert_eq(_packed_overlay(m, 1), NORMAL, "the overlay still shows water, not damage")
	assert_eq(m.base_overlay_state(1), WARNING, "but the damage was recorded")
	m.set_overlay_mode(&"none")
	assert_eq(_packed_overlay(m, 1), WARNING, "and it surfaces the moment the map is off")


func test_republishing_a_live_channel_repaints_and_drops_what_left_it() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.add_building(_view(2))
	m.set_overlay_channel(WATER, {1: CRITICAL, 2: CRITICAL})
	m.set_overlay_mode(WATER)
	# The next hour settles: building 1 recovered, building 2 dropped out of the
	# table entirely (it was demolished from the water graph's point of view).
	m.set_overlay_channel(WATER, {1: NORMAL})
	assert_eq(_packed_overlay(m, 1), NORMAL)
	assert_eq(_packed_overlay(m, 2), NORMAL, "an id that left the table goes back to its own")
	assert_eq(m.overlay_channel(WATER).size(), 1)


func test_channels_are_per_mode_and_switching_between_them_is_clean() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.set_overlay_channel(WATER, {1: OFFLINE})
	m.set_overlay_channel(&"police", {1: WARNING})
	m.set_overlay_mode(WATER)
	assert_eq(_packed_overlay(m, 1), OFFLINE)
	m.set_overlay_mode(&"police")
	assert_eq(_packed_overlay(m, 1), WARNING, "the other channel takes over")
	m.clear_overlay_channel(&"police")
	assert_eq(_packed_overlay(m, 1), NORMAL, "clearing the live channel un-paints it")
	assert_eq(m.overlay_channel(WATER).size(), 1, "and leaves the others alone")


func test_a_building_placed_under_an_overlay_joins_it_immediately() -> void:
	var m := _model()
	m.set_overlay_channel(WATER, {7: OFFLINE})
	m.set_overlay_mode(WATER)
	m.add_building(_view(7))
	assert_eq(_packed_overlay(m, 7), OFFLINE,
			"a dry lot must not read NORMAL just because it is new")
	m.set_overlay_mode(&"none")
	assert_eq(_packed_overlay(m, 7), NORMAL)


func test_the_channel_marks_instances_dirty_so_the_buffer_actually_moves() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.flush_dirty(Vector3.ZERO, 1000000)
	assert_eq(m.dirty_instance_count(), 0, "clean to start")
	m.set_overlay_channel(WATER, {1: CRITICAL})
	m.set_overlay_mode(WATER)
	assert_true(m.dirty_instance_count() > 0, "the repaint queued a write")
	m.flush_dirty(Vector3.ZERO, 1000000)
	var rec := m.building(1)
	var packed := m.mirror_custom(rec.chunk, rec.archetype, rec.level, rec.slot).b
	assert_eq(int(RenderStateModel.unpack_state(packed)["overlay"]), CRITICAL,
			"and the mirror the MultiMesh uploads carries it")


func test_a_removed_building_leaves_no_saved_base_behind() -> void:
	var m := _model()
	m.add_building(_view(1))
	m.set_overlay_channel(WATER, {1: CRITICAL})
	m.set_overlay_mode(WATER)
	m.remove_building(1)
	m.set_overlay_mode(&"none")
	assert_eq(m.building(1), null, "and the restore did not resurrect a record")


func test_the_shell_seam_is_the_ui_classifier_plus_the_render_channel() -> void:
	# End to end, headless: doc 05's numbers → OverlayModel's bands → the packed
	# state the shader tints. This is exactly what main.gd's hourly feed does.
	var overlay := OverlayModel.load_from_files()
	var m := _model()
	m.add_building(_view(1))
	m.add_building(_view(2))
	m.add_building(_view(3))
	m.add_building(_view(4))
	# Render ids, already translated by the shell's `_render_id(sim_id)`.
	var factors := {1: 0.98, 2: 0.60, 3: 0.20, 4: 0.0}
	m.set_overlay_channel(WATER, overlay.water_states(factors))
	m.set_overlay_mode(WATER)
	assert_eq(_packed_overlay(m, 1), NORMAL, "a tap at full pressure")
	assert_eq(_packed_overlay(m, 2), WARNING, "one that is dribbling")
	assert_eq(_packed_overlay(m, 3), CRITICAL, "one nearly dry")
	assert_eq(_packed_overlay(m, 4), OFFLINE, "and one with nothing at all")


# ===========================================================================
# The road overlay (mode 5)
# ===========================================================================

func _road_view() -> RoadOverlayView:
	var view := RoadOverlayView.new()
	_tree().root.add_child(view)
	view.setup(UIConfig.load_from_files())
	return view


func _drop(view: RoadOverlayView) -> void:
	_tree().root.remove_child(view)
	view.free()


static func _edge(tiles: Array, band: String) -> Dictionary:
	var typed: Array[Vector2i] = []
	for t: Variant in tiles:
		typed.append(t)
	return {"edge_id": 1, "tiles": typed, "band": band, "congestion": 0.0}


func test_the_road_overlay_paints_one_quad_per_road_tile() -> void:
	var view := _road_view()
	var painted := view.apply_edges([
		_edge([Vector2i(3, 4), Vector2i(4, 4)], "clear"),
		_edge([Vector2i(5, 4)], "gridlock"),
	])
	assert_eq(painted, 3)
	assert_eq(view.tile_count(), 3)
	assert_eq(view.band_of_tile(Vector2i(3, 4)), &"clear")
	assert_eq(view.band_of_tile(Vector2i(5, 4)), &"gridlock")
	assert_eq(view.mesh_instance().multimesh.visible_instance_count, 3)
	_drop(view)


func test_a_shared_tile_takes_the_worse_band() -> void:
	# An intersection between a clear street and a jammed arterial is not clear.
	var view := _road_view()
	view.apply_edges([
		_edge([Vector2i(1, 1), Vector2i(2, 1)], "clear"),
		_edge([Vector2i(2, 1), Vector2i(3, 1)], "severe"),
	])
	assert_eq(view.band_of_tile(Vector2i(2, 1)), &"severe")
	assert_eq(view.band_of_tile(Vector2i(1, 1)), &"clear")
	# Order must not matter: the same two edges the other way round agree.
	var mirrored := _road_view()
	mirrored.apply_edges([
		_edge([Vector2i(2, 1), Vector2i(3, 1)], "severe"),
		_edge([Vector2i(1, 1), Vector2i(2, 1)], "clear"),
	])
	assert_eq(mirrored.band_of_tile(Vector2i(2, 1)), &"severe")
	_drop(view)
	_drop(mirrored)


func test_an_edge_with_no_band_name_is_classified_from_its_congestion() -> void:
	var view := _road_view()
	view.apply_edges([
		{"edge_id": 1, "tiles": [Vector2i(0, 0)] as Array[Vector2i], "congestion": 0.95},
		{"edge_id": 2, "tiles": [Vector2i(1, 0)] as Array[Vector2i], "congestion": 0.10},
	])
	assert_eq(view.band_of_tile(Vector2i(0, 0)), &"gridlock")
	assert_eq(view.band_of_tile(Vector2i(1, 0)), &"clear")
	_drop(view)


func test_the_band_colour_comes_from_the_palette_the_legend_paints_with() -> void:
	var view := _road_view()
	var cfg := UIConfig.load_from_files()
	var palette := cfg.palette("default")
	view.apply_edges([_edge([Vector2i(0, 0)], "heavy")])
	var paint := view.paint_of_band(&"heavy")
	# LINEAR, since Wave 17 (doc 91 A91-D-36, report 98 RR-95): the band is a
	# MultiMesh INSTANCE colour, which takes no sRGB decode, so the view decodes
	# the legend hex once per band. Asserting the raw hex here would pin the
	# lift back in — the road band and the legend chip beside it have to be the
	# same colour on the screen, not in the file.
	var expected := Color(str(palette["warning"])).srgb_to_linear()
	assert_almost_eq((paint["color"] as Color).r, expected.r, 0.001,
			"heavy wears the legend's WARNING hue, decoded once")
	assert_true((paint["color"] as Color).r < Color(str(palette["warning"])).r,
			"…and the stored value is DARKER than the raw hex — the lift is out")
	assert_true((paint["color"] as Color).a > 0.0, "and a wash alpha")
	# Gridlock deepens the same hue rather than inventing a sixth colour, so a
	# colourblind palette carries it too.
	var grid := view.paint_of_band(&"gridlock")
	var crit := Color(str(palette["critical"])).srgb_to_linear()
	assert_true((grid["color"] as Color).r < crit.r, "gridlock is a deepened CRITICAL")
	assert_true(float(grid["hz"]) > 0.0, "and it moves")
	_drop(view)


func test_the_road_overlay_is_invisible_and_free_until_mode_5() -> void:
	var view := _road_view()
	view.apply_edges([_edge([Vector2i(0, 0)], "severe")])
	assert_false(view.is_active(), "it starts down")
	assert_false(view.mesh_instance().visible)
	assert_eq(view.draw_calls(), 0, "and costs nothing while it is")
	view.set_overlay_mode(&"traffic")
	assert_true(view.is_active())
	assert_true(view.mesh_instance().visible)
	assert_eq(view.draw_calls(), 1, "§2.13: the whole overlay is ONE draw call")
	view.set_overlay_mode(&"water")
	assert_false(view.is_active(), "any other overlay puts it away")
	_drop(view)


func test_repainting_the_same_tile_set_keeps_its_slots() -> void:
	# The minute-by-minute path: same graph, new congestion. Nothing reallocates
	# and nothing reorders, or the city would shimmer once a game-minute.
	var view := _road_view()
	var tiles := [Vector2i(9, 9), Vector2i(8, 9), Vector2i(7, 9)]
	view.apply_edges([_edge(tiles, "clear")])
	var before := view.mesh_instance().multimesh.get_instance_transform(0)
	view.apply_edges([_edge(tiles, "gridlock")])
	assert_eq(view.mesh_instance().multimesh.get_instance_transform(0), before,
			"the transforms were not rewritten")
	assert_eq(view.band_of_tile(Vector2i(7, 9)), &"gridlock", "but the colours were")
	assert_eq(view.tile_count(), 3)
	_drop(view)


# ===========================================================================
# The shaders — source contracts a headless suite CAN check
# ===========================================================================

func test_the_building_shader_decodes_water_out_of_the_same_two_bits() -> void:
	var src := FileAccess.get_file_as_string("res://game/shaders/building.gdshader")
	assert_ne(src, "", "the building shader is on disk")
	assert_true(src.contains("OVERLAY_MODE_WATER = 2"),
			"mode 2 is water, matching overlay.modes' index")
	assert_true(src.contains("overlay_paint("),
			"POWER and WATER share one state→hue decoder, so they cannot drift")
	assert_true(src.contains("sc_overlay_mode > 0"),
			"mode 0 still skips the whole block: the no-overlay frame is bit-exact")
	# The 112 stride is C-64's packing and nothing here may move it.
	assert_true(src.contains("packed / 112.0"))


func test_the_road_overlay_shader_carries_three_channels_not_one() -> void:
	var src := FileAccess.get_file_as_string("res://game/shaders/road_overlay.gdshader")
	assert_ne(src, "", "the road overlay shader is on disk")
	assert_true(src.contains("OVERLAY_MODE_TRAFFIC = 5"),
			"mode 5 is traffic, matching overlay.modes' index")
	assert_true(src.contains("blend_mix"), "the wash is translucent over the road")
	assert_true(src.contains("depth_draw_never"), "and never writes depth")
	assert_true(src.contains("stripe"), "the hatch is the channel that survives greyscale")
	assert_true(src.contains("MODEL_MATRIX"),
			"the hatch coordinate is world space, so stripes cross tile seams")
