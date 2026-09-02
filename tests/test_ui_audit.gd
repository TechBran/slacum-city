extends SimTest
## The screen sweep, as a test (doc 12 §2.1's breakpoints, A1/A2's "no clipped
## text", A3's touch floor).
##
## Every defect this file guards against was found by eye, on a phone-sized
## screenshot, after the deck had been green for three waves — because the whole
## suite ran at the 880 dp reference box and every screen fits at 880 dp. The
## three that mattered:
##
##   * the top bar's minimum width exceeded a 412 dp display, so `grow_horizontal
##     = BOTH` centred the overflow and pushed the ☰ button — the only way into
##     the pause menu — off the right edge;
##   * the build sheet's seven category tabs made the sheet 768 dp wide, which
##     put `GRID` and the ✕ off screen, and GRID is where the tutorial sends the
##     player in step 6;
##   * a `Label` with `clip_text` reports a minimum width of one pixel, so the
##     dashboard's axis figures and the economy tab's totals were laid out one
##     pixel wide and simply were not there.
##
## All three are **minimum-size** facts, which is what makes them testable without
## a rendered frame: a headless run never flushes a `Container`'s queued sort, so
## `size` is zero everywhere, but `get_combined_minimum_size()` and the theme are
## both live. `tools/ui_preview.gd --audit` is the pixel-accurate companion pass;
## this is the one that runs in the suite.

## Compact phone, common phone, Fold inner display, and the doc's own landscape
## reference box. Every surface has to fit every one of them.
const BOXES: Array[Vector2i] = [
	Vector2i(360, 800), Vector2i(412, 915), Vector2i(794, 924), Vector2i(880, 400),
	Vector2i(1280, 720),  # the project's own viewport (doc 91 D-12's blind spot)
	# **`data/ui.json.layout.min_safe_box_dp` — the project's own authored floor,
	# and until now the one box no `BOXES` list in the repository contained**
	# (A91-D-29). Doc 12 §2.18's A2 names it as the size the layout must survive
	# 150 % at; measured for the first time by the Wave-12 audit it put the title
	# screen's CANCEL 26 dp off the bottom at DEFAULT text scale. A requirement
	# whose own geometry nothing runs is not a gate, so it is a row here now.
	Vector2i(640, 340),
]

## Node paths, from the safe area, of every surface that occupies the full width
## of the display when it is up.
const SURFACES: Array[String] = [
	"HUDLayer/TopBar",
	"HUDLayer/AlertStack",
	"HUDLayer/OverlayRail/Strip",
	"PanelLayer/AlertsCenter/Panel",
	"PanelLayer/IncidentDrawer/Panel",
	"PanelLayer/BuildingPanel/Panel",
	"PanelLayer/LandPanel/Panel",
	"SheetLayer/BuildSheet/Sheet",
	"SheetLayer/BuildSheet/PlacementBar",
	"SheetLayer/UnitPicker/Sheet",
	"ModalLayer/CityDashboard/Panel",
	"ModalLayer/GoalsSheet/Panel",
	"ModalLayer/SettingsSheet/Panel",
	"ModalLayer/SaveLoadSheet/Panel",
	"ModalLayer/PauseMenu/Panel",
	"CoachLayer/Onboarding/CoachMark/Bubble",
	# S0. The one surface a player meets before anything else, and the one that
	# carries the longest single sentence in the deck (the "no free slot" line),
	# so it is the one most likely to blow a 360 dp box.
	"TitleLayer/TitleScreen/Center/Panel",
	# S15. The other surface a player meets with no city behind it, and the only
	# one that can be up while the sim is half-restored.
	"VeilLayer/LoadingVeil/Center/Panel",
]


## The read-only half of `game/save_service.gd` that S0 talks to. One occupied
## autosave, so the front door has a city to offer and a confirmation to price.
class SlotStub extends RefCounted:
	func list_slots() -> Array[Dictionary]:
		return [{"slot": 0, "saved_at_unix": 1755500000, "day_index": 12,
				"population": 184291, "treasury": 8420000}]

	func latest_slot() -> int:
		return 0

	func autosave_slots() -> Array[int]:
		return [0, 7]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Mounts the deck with every screen open at once. Nothing here is a state a
## player reaches — the point is to measure every surface in one pass, and a
## surface's minimum width does not depend on which of its siblings is up.
func _mount(text_scale: float = 1.0, larger_targets: bool = false,
		panel: String = "drawer") -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	# Injected before the scene enters the tree: every screen reads the two A2/A3
	# settings once, in its own `setup()`.
	root.config = UIConfig.load_from_files()
	var defaults: Dictionary = root.config.ui_data()["defaults"]
	defaults["text_scale"] = text_scale
	defaults["larger_touch_targets"] = larger_targets
	_tree().root.add_child(root)
	root.initialize()
	_populate(root, panel)
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


func _populate(root: UIRoot, panel: String = "drawer") -> void:
	root.hud.refresh(_snapshot())
	root.ingest_service({"power01": 0.41, "water01": 0.22})
	root.refresh_incidents([_incident_row()], 24.0)
	root.set_unit_provider(func(_id: int) -> Array:
		return [{"id": 1, "dept": "fire", "kind": "engine", "eta_gs": 48.0,
				"state": "IDLE"},
			{"id": 4, "dept": "police", "kind": "patrol_car", "eta_gs": -1.0,
				"state": "REFIT", "frees_in_gs": 420.0}])
	root.sample_history({"hour": 1, "treasury": 8_420_000.0, "population": 182_904.0,
			"net_per_hour": 5750.0, "happiness": 0.64, "stability": 0.71,
			"power01": 0.93, "water01": 0.71})
	root.feed_settlement({"hour": 1,
			"revenue": {"tax": 12480.0, "power_tariff": 940.0, "gross": 13420.0},
			"expenses": {"building_maint": 4120.0, "departments": 2260.0,
					"total": 6380.0},
			"net": 7040.0})
	root.alerts_center.set_clock(372, 2)
	root.alerts_center.feed_batch([
		{"type": "BlockDarkChanged", "block_id": "Harbour", "block_dark": true},
		{"type": "PowerComponentFailed", "component": "T-04", "cause": "overload"},
	])
	# Every surface up at once, plus the tutorial's first card, so the walk sees
	# the coach bubble's buttons too. `PanelLayer` allows exactly one open surface
	# (`UIWidgets.close_siblings`), so which of the three that is comes in.
	root.incident_drawer.open()
	root.unit_picker.open_for(root.incident_drawer.model.row(31))
	root.build_sheet.open()
	root.overlay_rail.open()
	root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
	# S14 is the one screen in the deck whose model reads a live sim, and an
	# unpopulated goals sheet would be measured with no objective rows in it —
	# i.e. measured at a width it never has in the game. It is given a founding
	# city, which is the state its longest sentences are written for.
	#
	# The goal CHIP is deliberately not fed here: it is a top-bar chip, the top
	# bar is already at its 360 dp / 130 % limit without it (see the
	# `_hide_lowest` note in `HudModel`), and this file's surface checks are the
	# ones that would have to change. The chip's own bar behaviour is swept from
	# 480 to 1200 dp in `tests/test_ui_goals.gd` and photographed by
	# `tools/ui_preview.gd --screen=hud --no-goal-chip` on both sides.
	root.goals_sheet.setup(root.config,
			GoalsModel.new(CitySim.boot_from_files(), root.config, null))
	root.goals_sheet.open()
	root.settings_sheet.open()
	root.save_load_sheet.open()
	root.pause_menu.open()
	root.start_onboarding({"tutorial_lot_a": Vector2i(43, 40)})
	# S0, with a save behind it so CONTINUE carries a real meta line rather than
	# the empty one. Only the title's own service is bound — the save sheet keeps
	# the state the other checks in this file were written against.
	root.title_screen.bind_service(SlotStub.new())
	root.present_title()
	# S15, mid-restore on the benchmark city's step count. Up at the same time as
	# everything else for this file's reason: a surface's minimum width does not
	# depend on which of its siblings is showing, and a veil nobody raises is a
	# veil this walk cannot measure.
	root.present_veil_load(UIWidgets.t(root.config, "ui_saves_slot_autosave"), 11)
	root.advance_veil_load(7)
	# Wave 17's tilt slider draws nothing without an axis; a fresh `CameraState`
	# puts the column into this walk the way `game/main.gd` puts the live one.
	var cam := CameraState.new(root.config.camera(), root.config.projection_fov_deg(40.0),
			{"tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7]})
	root.bind_camera(cam)
	match panel:
		"alerts":
			root.alerts_center.open()
		"building":
			var sim := CitySim.boot_from_files()
			var building_panel := root.safe_area.get_node_or_null(
					"PanelLayer/BuildingPanel") as BuildingPanel
			building_panel.setup(root.config, BuildController.new(sim))
			var ids := sim.buildings.keys()
			ids.sort()
			building_panel.show_building(str(ids[0]))
		"land":
			# S4 on a block the starter city leaves purchasable, which is the
			# state with the most rows in it: price, risks, advantages, six
			# phases and whatever the treasury is refusing today.
			var sim := CitySim.boot_from_files()
			root.land_panel.setup(root.config,
					LandPanelModel.new(sim, RequirementFormatter.new(root.config),
							root.config))
			root.land_panel.show_block(_purchasable_block(sim))
		_:
			root.incident_drawer.open()


## The first block the starter city offers for sale, found by asking the world
## rather than by naming one — doc 09's map may move.
static func _purchasable_block(sim: CitySim) -> String:
	for id: Variant in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(id))
		if block.ownership_state == &"PURCHASABLE":
			return String(id)
	return String(sim.world.block_ids_sorted()[0])


static func _snapshot() -> Dictionary:
	return {"population": 182904, "treasury": -1_240_000, "net_per_hour": -8200.0,
			"stability": 0.18, "happiness": 0.31,
			"incidents": {"count": 14, "worst_tier": 5},
			"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1,
			"paused": false}


static func _incident_row() -> Dictionary:
	return {"id": 31, "type": "structure_fire", "subtype": "", "tier": 4,
			"severity": 4.6, "status": "ASSIGNED", "pos": [12, 20],
			"district_id": "Harbour", "wait_min": 47.0, "assigned": [7],
			"assist_ratio": 0.0, "progress": 0.2, "escalation_eta_min": 12.0,
			"priority": 100.0, "pinned": false, "seen": false, "unreachable": false,
			"notification_priority": 2}


# ===========================================================================
# Widths
# ===========================================================================

func test_every_surface_fits_every_supported_display() -> void:
	for box: Vector2i in BOXES:
		var root := _mount()
		root.hud.set_width_dp(float(box.x))
		root.hud.refresh(_snapshot())
		for path: String in SURFACES:
			var surface := root.safe_area.get_node_or_null(path) as Control
			assert_ne(surface, null, "%s is in the scene" % path)
			if surface == null:
				continue
			var wanted := surface.get_combined_minimum_size().x
			assert_true(wanted <= float(box.x),
					"%s needs %d dp on a %d dp display" % [path, int(wanted), box.x])
		_unmount(root)


func test_every_surface_fits_the_narrowest_display_at_130_percent_text() -> void:
	# A2: the text-size setting may not push a control off the screen. The coach
	# bubble is the one that used to — its 240 dp cap was a constant, so `GOT IT`
	# lost its last letter as soon as the type grew.
	var root := _mount(1.3, true)
	root.hud.set_width_dp(360.0)
	root.hud.refresh(_snapshot())
	for path: String in SURFACES:
		var surface := root.safe_area.get_node_or_null(path) as Control
		if surface == null:
			continue
		var wanted := surface.get_combined_minimum_size().x
		assert_true(wanted <= 360.0,
				"%s needs %d dp at 130 %% text on a 360 dp display"
				% [path, int(wanted)])
	_unmount(root)


# ===========================================================================
# Copy in the tree
# ===========================================================================

func test_no_screen_shows_a_raw_key_or_an_unfilled_placeholder() -> void:
	for panel: String in ["drawer", "alerts", "building", "land"]:
		var root := _mount(1.0, false, panel)
		var findings := UIAudit.walk_frame_free(root.safe_area)
		assert_eq(UIAudit.format(findings, ""), "  clean",
				"every visible label resolved its copy (%s open)" % panel)
		_unmount(root)


func test_nothing_clips_without_a_width_to_clip_within() -> void:
	# The `unbounded_clip` rule, stated once: a Control that may shorten its own
	# text reports a minimum width of 0 (Button) or 1 (Label), so beside an
	# `EXPAND_FILL` sibling it is erased rather than shortened. `UIWidgets.elide()`
	# is the way to say "this may shorten", and it supplies the floor.
	for scale: float in [1.0, 1.3]:
		var root := _mount(scale)
		var findings := UIAudit.only(UIAudit.walk(root.safe_area, 0.0, Rect2()),
				[UIAudit.KIND_UNBOUNDED_CLIP])
		assert_eq(UIAudit.format(findings, ""), "  clean",
				"no unbounded clipping at %d %% text" % int(scale * 100.0))
		_unmount(root)


func test_every_target_names_itself() -> void:
	# A15: a Button with no `tooltip_text` has no accessibility name.
	for panel: String in ["drawer", "alerts", "building", "land"]:
		var root := _mount(1.0, false, panel)
		var findings := UIAudit.only(UIAudit.walk(root.safe_area, 0.0, Rect2()),
				[UIAudit.KIND_NO_TOOLTIP])
		assert_eq(UIAudit.format(findings, ""), "  clean", "%s open" % panel)
		_unmount(root)


# ===========================================================================
# The solvers the widths depend on
# ===========================================================================

func test_a_side_panel_takes_the_whole_phone_rather_than_leaving_a_ribbon() -> void:
	# 412 dp of display and a 364 dp panel left 48 dp of half-drawn HUD chip down
	# the left edge, which reads as a rendering fault rather than as a panel.
	assert_almost_eq(UIWidgets.side_panel_width(412.0, 364.0, 0.34, 260.0, 340.0, 48.0),
			412.0, 0.001)
	assert_almost_eq(UIWidgets.side_panel_width(880.0, 300.0, 0.34, 260.0, 340.0, 48.0),
			300.0, 0.001, "a wide display keeps the doc's ratio")
	assert_almost_eq(UIWidgets.side_panel_width(880.0, 320.0, 0.34, 260.0, 340.0, 48.0),
			320.0, 0.001, "and never squeezes its own contents")


func test_the_bottom_right_corner_is_a_rail_and_not_a_pile() -> void:
	# Three affordances share that corner — the drawer's tab, the alerts chip and
	# the event-log chip — and each used to carry a hard-coded offset pair sized
	# for a 48 dp target. At 130 % text with larger targets the chips measure
	# 100 dp tall and the tab 94 dp wide, and the pile-up was worth 73 findings a
	# box across 37 of 50 screens.
	var layout := UIConfig.load_from_files().layout()

	# At the authored scale the solver must reproduce the scene byte-for-byte, or
	# every screenshot in the repo moves for a bug that is not on any of them.
	var alerts := UIWidgets.corner_slot(1, layout, 48.0, 48.0, 56.0)
	assert_almost_eq(float(alerts["bottom"]), 92.0, 0.001)
	assert_almost_eq(float(alerts["height"]), 48.0, 0.001)
	var log_chip := UIWidgets.corner_slot(2, layout, 48.0, 48.0, 56.0)
	assert_almost_eq(float(log_chip["bottom"]), 148.0, 0.001,
			"the second chip clears the first by rail_gap_dp")

	# And at 130 % with larger targets the gap has to hold at the measured
	# height, which is the whole point of solving it rather than authoring it.
	var big_first := UIWidgets.corner_slot(1, layout, 56.0, 100.0, 102.0)
	var big_second := UIWidgets.corner_slot(2, layout, 56.0, 100.0, 102.0)
	assert_almost_eq(float(big_first["height"]), 100.0, 0.001)
	assert_almost_eq(float(big_second["bottom"])
			- (float(big_first["bottom"]) + float(big_first["height"])), 8.0, 0.001,
			"one rail_gap_dp of clear air between two 100 dp chips")
	assert_almost_eq(float(big_second["right"]), 102.0, 0.001,
			"and both keep out of the column the tab reserved")


func test_the_left_rail_is_one_stack_with_one_pitch() -> void:
	# §2.3's left rail lives in three files on TWO layers, so nobody could walk a
	# parent to find it and each file placed its own control against its own
	# measurement. `OverlayRail._build_button()` measures inside `setup()` —
	# before the theme has propagated and before anything is laid out — and read
	# 73 dp, while `CityHUD.refresh()` re-places the speed rail every frame and
	# read the laid-out 93: **28 dp of gap where `rail_gap_dp` says 8.**
	var layout := UIConfig.load_from_files().layout()
	var stack: Array = []
	var controls: Array[Control] = []
	for spec: Array in [[0, 62.0], [1, 73.0], [2, 93.0]]:
		var control := Control.new()
		control.custom_minimum_size = Vector2(56.0, float(spec[1]))
		controls.append(control)
		stack.append({"control": control, "index": int(spec[0])})
	var pitch := UIWidgets.solve_rail_stack(stack, layout, 73.0)
	assert_almost_eq(pitch, 93.0, 0.001,
			"one pitch for the whole column: the tallest member's")
	var gap := UIConfig.get_num(layout, "rail_gap_dp", 8.0)
	for i in range(1, controls.size()):
		# Offsets are negative and measured up from the bottom edge, so the slot
		# above is the one with the more negative top.
		assert_almost_eq(controls[i - 1].offset_top - controls[i].offset_bottom,
				gap, 0.001, "one rail_gap_dp between slot %d and slot %d" % [i - 1, i])
	for control in controls:
		assert_almost_eq(control.offset_bottom - control.offset_top, pitch, 0.001,
				"and every slot is the same height")
	for control in controls:
		control.free()


func test_a_stack_shorter_than_the_fab_still_keeps_the_fabs_pitch() -> void:
	# The pitch floor is `max(fab_d_dp, rail_button_d_dp, touch_min)` and it is
	# not the FAB's to claim alone — solving the stack must not shrink the column
	# at 100 % text, or every screenshot in the repo moves for a bug that is not
	# on any of them.
	var layout := UIConfig.load_from_files().layout()
	var stack: Array = []
	var controls: Array[Control] = []
	for index in 3:
		var control := Control.new()
		control.custom_minimum_size = Vector2(48.0, 48.0)
		controls.append(control)
		stack.append({"control": control, "index": index})
	var pitch := UIWidgets.solve_rail_stack(stack, layout, 48.0)
	assert_almost_eq(pitch,
			maxf(UIConfig.get_num(layout, "fab_d_dp", 64.0), 48.0), 0.001)
	assert_almost_eq(controls[0].offset_bottom,
			-UIConfig.get_num(layout, "rail_margin_dp", 12.0), 0.001,
			"and the bottom rung still sits one rail margin off the safe area")
	for control in controls:
		control.free()


func test_every_left_rail_member_answers_the_solver() -> void:
	# The mirror of the corner-rail test below: a member that forgets its
	# `rail_entry()` is one the solver cannot see, and it goes back to placing
	# itself with nothing failing.
	var root := _mount(1.3, true)
	var expected := {BuildSheet.RAIL_INDEX: root.build_sheet,
			OverlayRail.RAIL_INDEX: root.overlay_rail,
			CityHUD.RAIL_TOP_INDEX: root.hud}
	for index: int in expected:
		var screen: Node = expected[index]
		assert_true(screen.has_method("rail_entry"),
				"%s joins §2.3's rail stack" % screen.name)
		var entry: Dictionary = screen.call("rail_entry")
		assert_eq(int(entry.get("index", -1)), index)
		assert_ne(entry.get("control"), null,
				"every rail entry names a Control the solver can place")
	_unmount(root)


func test_the_corner_rail_is_solved_from_the_scene_not_from_its_offsets() -> void:
	# The three files must actually join the rail: an affordance that forgets its
	# `corner_rail_entry()` is one the solver cannot see, and it lands back on top
	# of its neighbour with nothing failing.
	var root := _mount(1.3, true)
	var drawer := root.safe_area.get_node_or_null(
			"PanelLayer/IncidentDrawer") as IncidentDrawer
	var alerts := root.safe_area.get_node_or_null(
			"PanelLayer/AlertsCenter") as AlertsCenter
	var log_screen := root.safe_area.get_node_or_null(
			"PanelLayer/EventLog") as EventLog
	assert_eq(int(drawer.corner_rail_entry().get("index", -1)), 0,
			"the drawer's handle is the tab, and the tab keeps the edge")
	assert_eq(int(alerts.corner_rail_entry().get("index", -1)), 1)
	assert_eq(int(log_screen.corner_rail_entry().get("index", -1)), 2)
	for entry: Dictionary in [drawer.corner_rail_entry(),
			alerts.corner_rail_entry(), log_screen.corner_rail_entry()]:
		assert_ne(entry.get("control"), null,
				"every rail entry names a Control the solver can place")
	_unmount(root)


func test_a_sheet_row_wraps_rather_than_widening_its_sheet() -> void:
	# D-47. An `HBox` asks for the sum of its children, so one 201 dp label beside
	# one 183 dp value chip made a 392 dp row, a 420 dp sheet and a ✕ 20 dp off
	# the right edge of a 360 dp phone. A flow container asks for its widest child
	# and drops the tail onto a second line. Asserted structurally because a
	# headless run has no text metrics to measure the collapse with.
	var root := _mount(1.3, true)
	# Inside the scroller's shared `Column` since A91-D-29: the About block moved
	# in beside the rows (`UIWidgets.scroll_into`), because a full-rect panel grows
	# through both edges rather than clipping and 164 dp of About outside the
	# scroller is what put this sheet's ✕ off the top of a 640 × 340 box.
	var rows := root.safe_area.get_node_or_null(
			"ModalLayer/SettingsSheet/Panel/Body/Scroll/Column/Rows") as VBoxContainer
	assert_ne(rows, null)
	assert_true(rows.get_child_count() > 0, "the settings sheet built its rows")
	for child in rows.get_children():
		var line: Node = child
		if not (line is FlowContainer):
			line = child.get_node_or_null("Line")
		assert_true(line is FlowContainer,
				"settings row %s wraps its value onto a second line" % child.name)
	var slots := root.safe_area.get_node_or_null(
			"ModalLayer/SaveLoadSheet/Panel/Body/Scroll/Slots") as VBoxContainer
	assert_ne(slots, null)
	assert_true(slots.get_child_count() > 0, "the save sheet built its slots")
	for slot in slots.get_children():
		assert_true(slot.get_node_or_null("Row/Actions") is FlowContainer,
				"%s wraps SAVE · LOAD · DELETE rather than widening the sheet"
				% slot.name)
	_unmount(root)


func test_the_top_bar_reserves_the_clock_column_on_every_row() -> void:
	# `HudModel._pack_rows` gives row 0 `avail` and every wrapped row the whole
	# bar. The scene has to actually be that shape, or row 1 is solved against a
	# width the container will not give it — which is how the ☰ button ended up
	# off screen. The clock and the menu therefore live *inside* row 0.
	var root := _mount()
	root.hud.set_width_dp(412.0)
	root.hud.refresh(_snapshot())
	var row0 := root.safe_area.get_node_or_null(
			"HUDLayer/TopBar/Chips/Row0") as Control
	assert_ne(row0, null)
	if row0 != null:
		assert_ne(row0.get_node_or_null("ClockChip"), null,
				"the clock shares row 0 with the chips")
		assert_ne(row0.get_node_or_null("MenuButton"), null,
				"and so does the pause-menu button")
	_unmount(root)
