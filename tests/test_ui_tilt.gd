extends SimTest
## Wave 17 — the right-edge TILT SLIDER (doc 12 §2.23), headless. The control is
## a thin skin over `CameraState`'s manual pitch axis, so most of the geometry
## and every angle are asserted through the camera it drives; what is asserted
## HERE is the skin: where the column lands at each supported box, that it
## yields the edge to a panel, that a drag reaches the axis at the column's own
## gain, that the double tap goes home, that the ghost fade obeys A8, and that
## the `camera` block joins the `ui` save section through the root.
##
## A headless mount has no frames, so the deck is laid out with
## `UIRoot.force_layout()` exactly as `tests/test_ui_audit.gd` does.

const BOXES: Array[Vector2i] = [
	Vector2i(360, 800), Vector2i(412, 915), Vector2i(794, 924), Vector2i(880, 400),
	Vector2i(1280, 720), Vector2i(640, 340),
]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount(box: Vector2i, text_scale: float = 1.0, larger: bool = false,
		reduce_motion: bool = false) -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	var defaults: Dictionary = root.config.ui_data()["defaults"]
	defaults["text_scale"] = text_scale
	defaults["larger_touch_targets"] = larger
	defaults["reduce_motion"] = reduce_motion
	_tree().root.add_child(root)
	root.initialize()
	root.hud.refresh({"population": 182904, "treasury": 8420000, "net_per_hour": 5750.0,
			"stability": 0.71, "happiness": 0.64, "incidents": {"count": 3, "worst_tier": 4},
			"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1, "paused": false})
	root.refresh_incidents([{"id": 31, "type": "structure_fire", "subtype": "", "tier": 4,
			"severity": 4.6, "status": "ASSIGNED", "pos": [12, 20], "district_id": "Harbour",
			"wait_min": 47.0, "assigned": [7], "assist_ratio": 0.0, "progress": 0.2,
			"escalation_eta_min": 12.0, "priority": 100.0, "pinned": false, "seen": false,
			"unreachable": false, "notification_priority": 2}], 24.0)
	root.refresh_goals()
	root.bind_camera(_camera())
	root.force_layout(box)
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


func _camera() -> CameraState:
	var cfg := UIConfig.load_from_files()
	var cam := CameraState.new(cfg.camera(), cfg.projection_fov_deg(40.0),
			{"tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7]})
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.42)
	return cam


## The band `UIRoot.solve_tilt_slider()` computes for a box, from the AUTHORED
## numbers — which is what it computes headless, because a mount with no frames
## has no laid-out top bar or drawer handle to measure and the solver falls back
## to the data at every one of its measurement points. The laid-out case is the
## one `tools/ui_preview.gd --audit` photographs; this is the case the suite can
## honestly assert.
func _authored_band(box: Vector2i) -> Vector2:
	var cfg := UIConfig.load_from_files()
	var layout := cfg.layout()
	var gap := UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	var handle_raw: Variant = layout.get("drawer_handle_dp", [44, 160])
	var handle_h := float((handle_raw as Array)[1]) \
			if handle_raw is Array and (handle_raw as Array).size() >= 2 else 160.0
	var reserve := UIConfig.get_num(layout, "drawer_handle_center_from_bottom_dp", 140.0) \
			+ maxf(handle_h, 48.0) * 0.5
	return Vector2(UIConfig.get_num(layout, "top_bar_h_dp", 48.0) + gap,
			float(box.y) - reserve - gap)


# ---------------------------------------------------------------------------
# Where it lands
#
# A headless mount has no frames and therefore no layout: `SafeArea` is a
# `MarginContainer` whose children are only fitted while the tree is visible, so
# every laid-out rect in the deck is 0x0 (this is why `tests/test_ui_audit.gd`
# walks `walk_frame_free` and why the other `force_layout` callers assert
# minimum SIZES and never positions). What is asserted here is therefore what
# the slider itself sets and owns — its anchors, its offsets, its stand-down —
# and not what a container would have done with them.
# ---------------------------------------------------------------------------

func test_the_column_is_a_48_dp_strip_on_the_right_edge_between_the_bar_and_the_handle() -> void:
	for box: Vector2i in BOXES:
		var root := _mount(box)
		var slider := root.tilt_slider
		assert_ne(slider, null, "the slider is in the scene")
		var band := _authored_band(box)
		var column := UIConfig.get_num(root.config.camera(), "tilt_slider_h_dp", 240.0)
		var floor_h := UIConfig.get_num(root.config.camera(), "tilt_slider_min_h_dp", 96.0)
		if slider.is_stood_down():
			assert_false(slider.visible, "%s: stood down means hidden" % box)
			assert_true(band.y - band.x < floor_h,
					"%s: stood down only where the band is under %d dp (%.0f)"
					% [box, int(floor_h), band.y - band.x])
			assert_true(box == Vector2i(640, 340),
					"%s: only the 640x340 floor box has no room for the column" % box)
			_unmount(root)
			continue
		assert_true(slider.visible, "%s: on screen" % box)
		# Flush with the right edge, one touch column wide, whatever the box:
		# anchored to the parent's right edge rather than positioned at a number.
		assert_almost_eq(slider.anchor_left, 1.0, 0.0001, "%s: anchored right" % box)
		assert_almost_eq(slider.anchor_right, 1.0, 0.0001, "%s: anchored right" % box)
		assert_almost_eq(slider.offset_right, 0.0, 0.01, "%s: flush with the right edge" % box)
		assert_almost_eq(slider.offset_left, -48.0, 0.5, "%s: one 48 dp touch column" % box)
		# Inside the band, centred in it, never taller than authored.
		var h := slider.offset_bottom - slider.offset_top
		assert_true(slider.offset_top >= band.x - 0.5,
				"%s: below the top bar (%.0f vs %.0f)" % [box, slider.offset_top, band.x])
		assert_true(slider.offset_bottom <= band.y + 0.5,
				"%s: above the drawer handle (%.0f vs %.0f)" % [box, slider.offset_bottom, band.y])
		assert_almost_eq((slider.offset_top + slider.offset_bottom) * 0.5,
				(band.x + band.y) * 0.5, 1.0, "%s: centred in the band" % box)
		assert_almost_eq(h, minf(column, band.y - band.x), 0.5,
				"%s: the authored column, or the band when that is shorter" % box)
		assert_almost_eq(slider.size.y, h, 0.5, "%s: and the control is that tall" % box)
		# The thumb rests on the middle detent, at A3 size.
		var thumb := slider.thumb_rect()
		assert_almost_eq(thumb.get_center().y, h * 0.5, 0.5, "%s: thumb at AUTO" % box)
		assert_true(thumb.size.x >= 48.0 and thumb.size.y >= 48.0, "%s: A3 thumb" % box)
		_unmount(root)


func test_the_column_is_a_named_target_with_a_tooltip_at_every_scale() -> void:
	# The geometry findings a frame-free walk cannot trust are filtered out the
	# way `tests/test_ui_audit.gd` filters them; what survives is what this deck
	# can answer headless — the thumb is a named, described target. Its rect is
	# checked against the real screen by `tools/ui_preview.gd --audit --strict`.
	for box: Vector2i in BOXES:
		for larger: bool in [false, true]:
			var scale := 1.3 if larger else 1.0
			var root := _mount(box, scale, larger)
			if not root.tilt_slider.visible:
				_unmount(root)
				continue
			var findings := UIAudit.walk_frame_free(root.safe_area)
			var mine: Array = []
			for row: Dictionary in findings:
				if str(row["path"]).contains("TiltSlider") or str(row["detail"]).contains("TiltSlider"):
					mine.append(row)
			assert_eq(UIAudit.format(mine, ""), "  clean",
					"%s at %d %%: the slider's thumb is a named, described target"
					% [box, int(scale * 100.0)])
			# A3: the thumb grows with the larger-targets setting.
			assert_true(root.tilt_slider.thumb_rect().size.y >= 48.0 * scale - 0.5,
					"%s at %d %%: the thumb is a touch target at this scale" % [box, int(scale * 100.0)])
			_unmount(root)


func test_the_slider_yields_the_edge_to_a_right_side_panel() -> void:
	var root := _mount(Vector2i(794, 924))
	assert_true(root.tilt_slider.visible)
	root.incident_drawer.open()
	root.solve_tilt_slider()
	assert_true(root.tilt_slider.is_yielding(), "the drawer has the edge")
	assert_false(root.tilt_slider.visible)
	root.incident_drawer.close()
	root.solve_tilt_slider()
	assert_false(root.tilt_slider.is_yielding())
	assert_true(root.tilt_slider.visible, "…and gives it back")
	root.alerts_center.open()
	root.solve_tilt_slider()
	assert_false(root.tilt_slider.visible, "any PanelLayer surface takes the edge")
	root.alerts_center.close()
	root.solve_tilt_slider()
	assert_true(root.tilt_slider.visible)
	_unmount(root)


func test_a_slider_with_no_camera_is_not_on_screen() -> void:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	_tree().root.add_child(root)
	root.initialize()
	root.force_layout(Vector2i(794, 924))
	assert_ne(root.tilt_slider, null)
	assert_false(root.tilt_slider.visible, "nothing to drive, nothing to draw")
	assert_false(root.capture_ui_state().has("camera"), "and no camera block to save")
	_unmount(root)


# ---------------------------------------------------------------------------
# What it does
# ---------------------------------------------------------------------------

func test_a_drag_up_the_column_leans_the_camera_toward_the_facades() -> void:
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	var cam := root.camera_state
	var curve := cam.pitch_deg()
	var mid := slider.column_height() * 0.5
	var half := slider.half_travel()
	assert_true(half > 40.0, "a 240 dp column has real travel (%f)" % half)
	# The TOP OF THE TRACK, not the top of the column: at this zoom the up reach
	# has compressed the reachable half to `half · reach`, and the thumb's own
	# mapping is where the drag's gain is read from. (A drag past it is not an
	# error — it stretches the axis's rubber band and springs back to +1 — but
	# then the number under test would be the band, not the gain.)
	var top := slider.thumb_y_for_bias(1.0)
	assert_true(top < mid - 1.0, "the up track has room at this zoom (%f)" % top)
	slider.simulate_drag(mid, top, 32)
	assert_false(cam.is_pitch_auto())
	assert_almost_eq(cam.pitch_bias, 1.0, 0.001, "a full half-track is a full lean")
	assert_almost_eq(cam.pitch_deg(), cam.pitch_floor_deg_at(cam.zoom_t), 0.01,
			"…to the floor this zoom allows")
	assert_true(cam.pitch_deg() < curve)
	assert_almost_eq(slider.thumb_rect().get_center().y, top, 0.5, "thumb at the top")
	assert_false(cam.is_tilting(), "released")
	assert_false(cam.is_pitch_auto(), "release holds")
	# Down from there: past the middle to half the DOWN track, whose reach is its
	# own. The one sample that straddles the detent carries the gain it started
	# on, so the tolerance here is a step of that 32-step drag, not a bit.
	slider.simulate_drag(top, slider.thumb_y_for_bias(-0.5), 32)
	assert_almost_eq(cam.pitch_bias, -0.5, 0.02, "half a track below the detent")
	assert_true(cam.pitch_deg() > curve, "toward top-down")
	_unmount(root)


func test_the_column_takes_its_own_touches_and_no_others() -> void:
	# §2.23: the column must not capture a one-finger pan that started elsewhere,
	# and must not let a touch that started ON it reach the camera underneath.
	# Both are one mechanism: `_gui_input` is only offered events inside the
	# control's own rect, and the column calls `accept_event()` on every touch it
	# reads, which is what keeps it out of `TouchInput._unhandled_input`. What is
	# asserted here is the invariant that makes that routing correct — the column
	# STOPs, and the thumb inside it takes no input of its own, so a grab a few
	# dp off the glyph is still a grab rather than a dead press on a Button.
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	assert_eq(slider.mouse_filter, Control.MOUSE_FILTER_STOP, "the column stops events")
	assert_eq(slider.thumb_button().mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"the thumb is a target for the accessibility walk, not an input sink")
	assert_eq(slider.focus_mode, Control.FOCUS_NONE, "and it never steals focus")
	_unmount(root)


func test_a_press_on_the_track_jumps_then_grabs() -> void:
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	var cam := root.camera_state
	var mid := slider.column_height() * 0.5
	var half := slider.half_travel()
	# Press well below the thumb (on the track), no drag.
	slider.simulate_drag(mid + half * 0.8, mid + half * 0.8, 1)
	assert_almost_eq(cam.pitch_bias, -0.8, 0.02, "the axis jumped to the pressed point")
	_unmount(root)


func test_a_double_tap_snaps_home_and_reduce_motion_cuts() -> void:
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	var cam := root.camera_state
	var mid := slider.column_height() * 0.5
	slider.simulate_drag(mid, mid - slider.half_travel() * 0.7)
	assert_false(cam.is_pitch_auto())
	slider.simulate_double_tap()
	assert_true(cam.is_pitch_returning(), "the ease is the axis's")
	var steps := 0
	while cam.is_pitch_returning() and steps < 600:
		cam.advance(1.0 / 60.0)
		steps += 1
	assert_true(cam.is_pitch_auto(), "home is AUTO")
	assert_almost_eq(slider.thumb_y_for_bias(cam.pitch_bias), mid, 0.5, "thumb back on the detent")
	# A8: the same double tap is a cut.
	slider.apply_setting(&"reduce_motion", true)
	slider.simulate_drag(mid, mid - slider.half_travel() * 0.5)
	slider.simulate_double_tap()
	assert_true(cam.is_pitch_auto(), "reduce_motion: home immediately")
	assert_false(cam.is_pitch_returning())
	_unmount(root)


func test_the_column_ghosts_after_two_idle_seconds_and_wakes_on_touch() -> void:
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	assert_almost_eq(slider.modulate.a, 1.0, 0.001, "full on arrival")
	slider.advance(1.0)
	assert_almost_eq(slider.modulate.a, 1.0, 0.001, "still full at 1 s")
	slider.advance(1.5)
	slider.advance(0.5)
	assert_true(slider.is_ghosted(), "ghosted past tilt_slider_fade_after_s (a %.2f)" % slider.modulate.a)
	assert_almost_eq(slider.modulate.a, slider.ghost_alpha(), 0.001)
	var mid := slider.column_height() * 0.5
	slider.simulate_drag(mid, mid - 20.0, 2)
	assert_almost_eq(slider.modulate.a, 1.0, 0.001, "any touch brings it back to full")
	_unmount(root)


func test_reduce_motion_keeps_the_ghost_state_but_cuts_the_fade() -> void:
	var root := _mount(Vector2i(794, 924), 1.0, false, true)
	var slider := root.tilt_slider
	slider.advance(1.99)
	assert_almost_eq(slider.modulate.a, 1.0, 0.001, "not yet")
	slider.advance(0.02)
	assert_almost_eq(slider.modulate.a, slider.ghost_alpha(), 0.001,
			"A8: the ghost is a STATE and stays; only the fade — motion — is cut")
	_unmount(root)


func test_the_track_compresses_with_the_zoom_reach() -> void:
	var root := _mount(Vector2i(794, 924))
	var slider := root.tilt_slider
	var cam := root.camera_state
	cam.pitch_reach_up_near = 1.0
	cam.pitch_reach_up_far = 0.5
	cam.set_zoom_t(0.0)
	var half := slider.half_travel()
	assert_almost_eq(slider.thumb_y_for_bias(1.0), slider.column_height() * 0.5 - half, 0.01,
			"close in, bias +1 is the top of the column")
	cam.set_zoom_t(1.0)
	assert_almost_eq(slider.thumb_y_for_bias(1.0), slider.column_height() * 0.5 - half * 0.5, 0.01,
			"far out, the reachable track above the detent is half as long")
	assert_almost_eq(slider.bias_for_thumb_y(slider.column_height() * 0.5 - half * 0.5), 1.0, 0.001,
			"…and the inverse agrees")
	assert_almost_eq(slider.thumb_y_for_bias(-1.0), slider.column_height() * 0.5 + half, 0.01,
			"the down reach is still whole")
	_unmount(root)


# ---------------------------------------------------------------------------
# The save (doc 12 §3.2, D-68)
# ---------------------------------------------------------------------------

func test_the_camera_block_joins_the_ui_section_and_comes_back() -> void:
	var root := _mount(Vector2i(794, 924))
	var cam := root.camera_state
	cam.set_zoom_t(0.3)
	cam.yaw = deg_to_rad(90.0)
	cam.set_focus(Vector3(256.0, 0.0, 320.0))
	cam.set_pitch_bias(0.6)
	var state := root.capture_ui_state()
	assert_true(state.has("camera"), "the ui section carries the camera block")
	var block: Dictionary = state["camera"]
	for key: String in ["focus_x", "focus_z", "zoom_t", "yaw_deg", "pitch_mode", "pitch_bias"]:
		assert_true(block.has(key), "camera.%s" % key)
	assert_eq(str(block["pitch_mode"]), "manual")
	# A fresh deck restores it, pitch included, and the slider follows.
	var other := _mount(Vector2i(794, 924))
	other.restore_ui_state(state)
	var restored := other.camera_state
	assert_almost_eq(restored.zoom_t, 0.3, 0.000001)
	assert_almost_eq(rad_to_deg(restored.yaw), 90.0, 0.0001)
	assert_almost_eq(restored.focus.x, 256.0, 0.0001)
	assert_almost_eq(restored.pitch_bias, 0.6, 0.000001)
	assert_false(restored.is_pitch_auto())
	assert_almost_eq(other.tilt_slider.thumb_rect().get_center().y,
			other.tilt_slider.thumb_y_for_bias(0.6), 0.5, "the thumb shows the restored lean")
	# A section with no camera block leaves the camera alone.
	other.restore_ui_state({"section_version": 1})
	assert_almost_eq(other.camera_state.pitch_bias, 0.6, 0.000001)
	_unmount(other)
	_unmount(root)


func test_the_strings_the_slider_uses_exist() -> void:
	var cfg := UIConfig.load_from_files()
	for key: String in ["ui_tilt_slider", "ui_tilt_thumb"]:
		assert_true(cfg.has_string(key), "%s in data/strings.en.json" % key)
	var root := _mount(Vector2i(794, 924))
	assert_eq(root.tilt_slider.thumb_button().tooltip_text, cfg.t("ui_tilt_thumb"))
	assert_eq(root.tilt_slider.tooltip_text, cfg.t("ui_tilt_slider"))
	_unmount(root)


## **Wave 18 — the band's third measurement point** (doc 12 §2.23, report 98 §51).
## Wave 17 solved the column against the top bar and the drawer handle and never
## against §2.4's banner stack, which is as wide as the display allows: at
## 412 × 915, 130 % text with larger targets, `AlertStack/Alert1/Row/View`
## P(296, 296) S(94, 76) covered **1,155 px²** of the thumb at P(335, 351).
##
## The geometry itself is `tools/ui_preview.gd --audit --strict`'s to photograph
## — a headless mount lays nothing out, which is why every other assertion in
## this file is about authored numbers. The RULE is pure and is asserted here.
func test_a_banner_that_reaches_the_right_edge_pushes_the_band_down() -> void:
	# 412 dp box, 48 dp column, the two banners the 130 % sweep laid out.
	var wide: Array[Rect2] = [Rect2(12.0, 180.0, 388.0, 96.0),
			Rect2(12.0, 286.0, 388.0, 96.0)]
	assert_almost_eq(UIRoot.banner_band_top(56.0, wide, 412.0, 48.0), 382.0, 0.01,
			"the LOWEST banner's bottom, not the first one's")
	# The same call with no banners is the bar's own answer, unchanged — which is
	# what a headless mount hands it, and why `_authored_band` still holds.
	var none: Array[Rect2] = []
	assert_almost_eq(UIRoot.banner_band_top(56.0, none, 412.0, 48.0), 56.0, 0.01,
			"no banner, no push")
	# A banner short of the column may not move it: 794 dp, `alert_dp`'s 400 wide
	# centred, right edge 597 against a column that starts at 746.
	var narrow: Array[Rect2] = [Rect2(197.0, 180.0, 400.0, 96.0)]
	assert_almost_eq(UIRoot.banner_band_top(56.0, narrow, 794.0, 48.0), 56.0, 0.01,
			"a centred banner that never reaches the edge leaves the band alone")
	# And a zero-height row — a hidden alert panel a container still reports — is
	# not a banner. This is the guard that makes the headless case inert.
	var empty: Array[Rect2] = [Rect2(12.0, 180.0, 388.0, 0.0)]
	assert_almost_eq(UIRoot.banner_band_top(56.0, empty, 412.0, 48.0), 56.0, 0.01,
			"an unlaid-out row is not a banner")
	# Never upward: a banner above the bar cannot pull the band up into it.
	var above: Array[Rect2] = [Rect2(12.0, 4.0, 388.0, 20.0)]
	assert_almost_eq(UIRoot.banner_band_top(56.0, above, 412.0, 48.0), 56.0, 0.01,
			"the bar's bottom is a floor")
