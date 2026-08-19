extends SimTest
## Doc 12 §2.4 + A1/A2/A3/A15 — the top bar on a near-square display, and the
## accessibility tree walk over every screen this track added.
##
## The bug this file exists for: the §2.4 collapse solver budgets each chip at a
## fixed width and hides P5–P7 when it runs out, but on the Fold's inner display
## (2160 × 1856 px, ~1:1) the *measured* value strings are wider than those
## budgets, so chips clipped and readings vanished. The fix is two-sided —
## measured widths feed the solver, and the bar wraps to a second row before it
## hides anything — and both sides are asserted here at real device boxes.
##
## Device boxes, in dp (`UIRoot` sets `content_scale_factor = dpi/160`, so
## Control coordinates are dp on every device — §2.1):
##   Fold 6 inner, portrait   1856 × 2160 px @ ~374 dpi → ~794 × 924 dp
##   Fold 6 inner, landscape  2160 × 1856 px            → ~924 × 794 dp
##   1280 × 720 window @ 160 dpi                        → 1280 × 720 dp
##   the doc's guaranteed-safe minimum                  →  640 × 340 dp

const FOLD_PORTRAIT_DP := 794.0
const FOLD_LANDSCAPE_DP := 924.0
const WINDOW_720P_DP := 1280.0
const MIN_SAFE_DP := 640.0

## The §2.3 mock's snapshot: every chip at its widest realistic value.
const SNAPSHOT := {
	"treasury": 8420000, "net_per_hour": 5750.0, "population": 184291,
	"stability": 0.68, "incidents": {"count": 7, "worst_tier": 4},
	"grid_pct": 91.0, "water_pct": 97.0,
	"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 2, "paused": false,
}


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> HudModel:
	return HudModel.new(_cfg())


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return {"root": root, "hud": root.hud}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


## What a themed Button needs to draw `text` without clipping: the string plus
## the theme's own horizontal content margins. Computed here independently of
## `CityHUD`, so the two agreeing means something.
static func _needed_width(button: Button) -> float:
	var font := button.get_theme_font(&"font")
	if font == null or button.text == "":
		return 0.0
	var width := font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			button.get_theme_font_size(&"font_size")).x
	var box := button.get_theme_stylebox(&"normal")
	if box != null:
		width += box.content_margin_left + box.content_margin_right
	return width


# ===========================================================================
# The solver
# ===========================================================================

func test_measured_widths_widen_the_docs_budget_never_narrow_it() -> void:
	var model := _model()
	# A budget of 112 dp for `Moderate 68` is optimistic; the measured width wins.
	var solved := model.solve_top_bar(880.0, 132.0, {"stability": {"full": 160.0}})
	assert_almost_eq(float(solved["avail"]), 732.0, 0.001)
	# 676 (the doc's need) − 112 + 160 = 724, still inside 732, so nothing moves.
	assert_almost_eq(float(solved["need"]), 724.0, 0.001)
	assert_eq(int(solved["iterations"]), 0)
	# A chip measured narrower than its budget keeps the budget: the bar is a
	# grid, not a shrink-wrap.
	var narrow := model.solve_top_bar(880.0, 132.0, {"stability": {"full": 10.0}})
	assert_almost_eq(float(narrow["need"]), 676.0, 0.001)


func test_max_rows_one_is_byte_identical_to_the_doc() -> void:
	# Regression guard: the wrap must not have changed the single-row solver.
	var model := _model()
	var solved := model.solve_top_bar(640.0, 100.0)
	assert_almost_eq(float(solved["need"]), 508.0, 0.001)
	assert_eq(int(solved["iterations"]), 5)
	assert_eq((solved["visible"] as Array).size(), 7)
	assert_false(bool(solved["wrapped"]))
	assert_eq((solved["rows"] as Array).size(), 1)
	var tight := model.solve_top_bar(480.0)
	assert_eq((tight["modes"] as Dictionary)["stability"], HudModel.MODE_HIDDEN)
	assert_false(bool(tight["wrapped"]))


func test_the_bar_wraps_before_it_hides_anything() -> void:
	# The whole point: a wrapped chip is readable, a hidden one is gone.
	var model := _model()
	var single := model.solve_top_bar(480.0, 132.0, {}, 1)
	assert_eq((single["visible"] as Array).size(), 5, "single row hides P7 and P6")
	var wrapped := model.solve_top_bar(480.0, 132.0, {}, 2)
	assert_true(bool(wrapped["wrapped"]))
	assert_eq((wrapped["visible"] as Array).size(), 7, "two rows hide nothing")
	assert_eq((wrapped["rows"] as Array).size(), 2)
	for chip_id: String in model.chip_order():
		assert_eq((wrapped["modes"] as Dictionary)[chip_id], HudModel.MODE_COMPACT,
				"demotion still runs first — wrapping is the second resort")


func test_wrapped_rows_respect_their_own_width_limits() -> void:
	var model := _model()
	var solved := model.solve_top_bar(MIN_SAFE_DP, 132.0, {}, 2)
	var widths: Array = solved["row_widths"]
	var rows: Array = solved["rows"]
	assert_eq(widths.size(), rows.size())
	for i in rows.size():
		var limit := float(solved["avail"]) if i == 0 else float(solved["avail_rest"])
		assert_true(float(widths[i]) <= limit,
				"row %d is %d dp inside %d dp" % [i, int(widths[i]), int(limit)])
	# Every chip lands on exactly one row, and none is lost.
	var seen: Array[String] = []
	for row: Variant in rows:
		for chip_id: Variant in (row as Array):
			assert_false(seen.has(str(chip_id)), "%s appears once" % chip_id)
			seen.append(str(chip_id))
	assert_eq(seen.size(), (solved["visible"] as Array).size())


func test_wrapping_only_gives_up_when_even_the_last_row_is_full() -> void:
	# Absurdly narrow: two rows cannot hold seven chips, so the lowest priorities
	# finally go — but P1–P4 never do (§2.4's final `break`).
	var model := _model()
	var solved := model.solve_top_bar(220.0, 100.0, {}, 2)
	var modes: Dictionary = solved["modes"]
	for chip_id: String in ["treasury", "incidents", "grid", "water"]:
		assert_ne(modes[chip_id], HudModel.MODE_HIDDEN, "%s survives" % chip_id)
	assert_eq(modes["stability"], HudModel.MODE_HIDDEN, "P7 goes first")


func test_the_solver_is_deterministic_at_every_device_box() -> void:
	var model := _model()
	for width: float in [MIN_SAFE_DP, FOLD_PORTRAIT_DP, FOLD_LANDSCAPE_DP, WINDOW_720P_DP]:
		var a := model.solve_top_bar(width, 132.0, {"stability": {"full": 160.0,
				"compact": 96.0}}, 2)
		var b := model.solve_top_bar(width, 132.0, {"stability": {"full": 160.0,
				"compact": 96.0}}, 2)
		assert_eq(str(a["rows"]), str(b["rows"]), "same box, same layout")
		assert_true(int(a["iterations"]) <= 14, "bounded at W=%d" % int(width))


func test_data_asks_for_two_rows() -> void:
	assert_eq(_model().top_bar_max_rows(), 2,
			"data/ui.json.layout.top_bar_max_rows drives the wrap")


# ===========================================================================
# The mounted HUD at real device boxes
# ===========================================================================

## Every visible chip must be at least as wide as the text it is drawing, at
## every width the slice ships against. This is the assertion the Fold bug would
## have failed.
func test_no_chip_clips_at_any_device_box() -> void:
	var mounted := _mount()
	var hud: CityHUD = mounted["hud"]
	for width: float in [MIN_SAFE_DP, FOLD_PORTRAIT_DP, FOLD_LANDSCAPE_DP,
			WINDOW_720P_DP, 880.0]:
		hud.set_width_dp(width)
		hud.refresh(SNAPSHOT)
		var visible := 0
		for chip_id: String in hud.model.chip_order():
			var button := hud.chip_button(chip_id)
			if not button.visible:
				continue
			visible += 1
			assert_true(button.custom_minimum_size.x >= _needed_width(button) - 0.5,
					"%s at W=%d is %d dp for text needing %d dp" % [chip_id,
							int(width), int(button.custom_minimum_size.x),
							int(_needed_width(button))])
		assert_eq(visible, 7, "nothing is hidden at W=%d — it wraps instead" % int(width))
	_unmount(mounted)


func test_the_fold_inner_display_wraps_rather_than_dropping_readings() -> void:
	var mounted := _mount()
	var hud: CityHUD = mounted["hud"]
	hud.set_width_dp(FOLD_PORTRAIT_DP)
	hud.refresh(SNAPSHOT)
	var rows := hud.chip_rows()
	var placed := 0
	for row: Variant in rows:
		placed += (row as Array).size()
	assert_eq(placed, 7, "all seven readings are on screen")
	assert_true(rows.size() <= hud.model.top_bar_max_rows(),
			"and inside the row budget")
	# The banner stack follows the bar down instead of landing on the chips.
	var stack := mounted["root"].get_node("SafeArea/HUDLayer/AlertStack") as Control
	var bar := mounted["root"].get_node("SafeArea/HUDLayer/TopBar") as Control
	assert_true(stack.offset_top >= bar.get_combined_minimum_size().y,
			"the alert stack sits under the top bar, not on it")
	_unmount(mounted)


func test_a_wide_window_stays_on_one_row_with_full_chips() -> void:
	var mounted := _mount()
	var hud: CityHUD = mounted["hud"]
	hud.set_width_dp(WINDOW_720P_DP)
	hud.refresh(SNAPSHOT)
	assert_eq(hud.chip_rows().size(), 1, "1280 dp never needs a second row")
	assert_true(hud.chip_button("treasury").text.contains("$8.42M"))
	assert_true(hud.chip_button("stability").text.contains("Moderate"),
			"the wide layout keeps the word, not just the number")
	_unmount(mounted)


func test_re_solving_the_same_width_does_not_churn_the_tree() -> void:
	var mounted := _mount()
	var hud: CityHUD = mounted["hud"]
	hud.set_width_dp(FOLD_PORTRAIT_DP)
	hud.refresh(SNAPSHOT)
	var before := hud.chip_button("treasury").get_parent()
	hud.refresh(SNAPSHOT)
	assert_eq(hud.chip_button("treasury").get_parent(), before,
			"an unchanged layout re-parents nothing")
	_unmount(mounted)


# ===========================================================================
# A3 / A15 over every screen this track added
# ===========================================================================

func test_every_interactive_control_on_every_screen_meets_a3_and_a15() -> void:
	# doc 12 test 19, extended over the overlay rail, the alerts centre, the
	# settings sheet, the save slots and the pause menu. Buttons are asserted
	# whether or not their screen is open — a target that only becomes legal
	# once you can see it is not a gate.
	var mounted := _mount()
	var root: UIRoot = mounted["root"]
	root.overlay_rail.open()
	root.alerts_center.set_clock(372, 2)
	root.alerts_center.feed({"type": &"PowerComponentFailed", "component": "T-04",
			"cause": "overload"})
	root.alerts_center.open()
	root.bind_save_service(_StubService.new(), null)
	root.save_load_sheet.open()
	root.settings_sheet.open()
	root.pause_menu.open()

	var minimum := float(ThemeBuilder.touch_min_dp(root.config, 1.0, false))
	var checked := 0
	var seen: Array[String] = []
	for node: Node in _walk(root):
		var button := node as Button
		if button == null:
			continue
		checked += 1
		seen.append(str(button.name))
		assert_true(button.custom_minimum_size.x >= minimum,
				"%s is %d dp wide, needs %d" % [button.name,
						int(button.custom_minimum_size.x), int(minimum)])
		assert_true(button.custom_minimum_size.y >= minimum,
				"%s is %d dp tall, needs %d" % [button.name,
						int(button.custom_minimum_size.y), int(minimum)])
		assert_true(button.tooltip_text.strip_edges().length() > 0,
				"%s has an A15 name" % button.name)
	for expected: String in ["MenuButton", "Chip_power", "Chip_water", "MarkAll",
			"Value_graphics", "Save_0", "Delete_2", "Action_resume", "Action_quit",
			"Yes", "No"]:
		assert_true(seen.has(expected), "the walk reached %s" % expected)
	assert_true(checked >= 40, "the whole console was walked (%d buttons)" % checked)
	_unmount(mounted)


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out


class _StubService extends RefCounted:
	var slots: Dictionary = {}

	func save_slot(_sim: Variant, slot: int) -> Dictionary:
		var meta := {"slot": slot, "saved_at_unix": 1755500000, "day_index": 1,
				"population": 1000, "treasury": 5000}
		slots[slot] = meta
		return meta

	func load_slot(_sim: Variant, slot: int) -> bool:
		return slots.has(slot)

	func list_slots() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for key: Variant in slots:
			out.append(slots[key])
		return out

	func delete_slot(slot: int) -> bool:
		return slots.erase(slot)

	func autosave(sim: Variant) -> void:
		save_slot(sim, 0)
