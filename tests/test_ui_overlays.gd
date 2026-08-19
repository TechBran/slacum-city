extends SimTest
## Doc 12 §2.5 — the overlay rail: mutual exclusion, the enabled/disabled split
## while docs 05/06/10 are still landing, the `NONE ↔ last-used` long press, the
## four-state legend, and the `sc_overlay_mode` shader global doc 11 reads.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> OverlayModel:
	return OverlayModel.new(_cfg())


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> Dictionary:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false  # never touch the test runner's window
	_tree().root.add_child(root)
	root.initialize()
	var rail := root.get_node_or_null("SafeArea/HUDLayer/OverlayRail") as OverlayRail
	return {"root": root, "rail": rail}


func _unmount(mounted: Dictionary) -> void:
	var root: Node = mounted["root"]
	_tree().root.remove_child(root)
	root.free()


# ===========================================================================
# OverlayModel
# ===========================================================================

func test_modes_match_the_doc_and_index_is_the_shader_value() -> void:
	# §2.5: six overlays, mutually exclusive in MVP. The int doc 11 reads is the
	# position in that list, so the order in data/ui.json IS the wire format.
	var model := _model()
	var modes := model.modes()
	assert_eq(modes.size(), 6)
	assert_eq(modes[0], &"none")
	assert_eq(modes[1], &"power")
	assert_eq(model.mode_index(&"none"), 0)
	assert_eq(model.mode_index(&"power"), 1)
	assert_eq(model.mode_index(&"traffic"), 5)
	assert_eq(model.mode_index(&"nonsense"), -1)
	assert_eq(model.shader_global_name(), "sc_overlay_mode")


func test_only_power_is_live_and_the_rest_explain_themselves() -> void:
	var model := _model()
	assert_true(model.is_enabled(&"none"), "turning overlays off is never blocked")
	assert_true(model.is_enabled(&"power"), "doc 04 shipped")
	for mode: StringName in [&"water", &"police", &"fire", &"traffic"]:
		assert_false(model.is_enabled(mode), "%s has no sim yet" % mode)
		# A14: the chip stays listed with a reason, it does not disappear.
		var chip_ids: Array[StringName] = []
		for chip: Dictionary in model.chips():
			chip_ids.append(chip["id"])
		assert_true(chip_ids.has(mode), "%s is still on the strip" % mode)
	var cfg := _cfg()
	for chip: Dictionary in model.chips():
		assert_true(cfg.has_string(str(chip["label_key"])),
				"%s has copy" % chip["label_key"])
	assert_true(cfg.has_string("ui_overlay_disabled"))


func test_selection_is_mutually_exclusive_and_disabled_modes_are_refused() -> void:
	var model := _model()
	assert_eq(model.active(), OverlayModel.MODE_NONE)
	var power := model.select(&"power")
	assert_true(bool(power["ok"]))
	assert_true(bool(power["changed"]))
	assert_eq(model.active(), &"power")
	assert_eq(int(power["index"]), 1)

	var water := model.select(&"water")
	assert_false(bool(water["ok"]))
	assert_eq(water["reason"], OverlayModel.REASON_DISABLED)
	assert_eq(model.active(), &"power", "a refused select never moves the active one")

	var unknown := model.select(&"nonsense")
	assert_false(bool(unknown["ok"]))
	assert_eq(unknown["reason"], OverlayModel.REASON_UNKNOWN)

	# Selecting the active overlay again through `toggle` puts it away.
	assert_true(bool(model.toggle(&"power")["ok"]))
	assert_eq(model.active(), OverlayModel.MODE_NONE)


func test_long_press_toggles_none_and_last_used() -> void:
	# §2.5: "Long-pressing the Overlay button toggles NONE ↔ last-used overlay
	# (fast A/B compare)."
	var model := _model()
	assert_false(bool(model.toggle_last()["ok"]), "no history yet, so it is a no-op")
	model.select(&"power")
	assert_eq(model.last_used(), &"power")
	model.select(OverlayModel.MODE_NONE)
	assert_eq(model.active(), OverlayModel.MODE_NONE)
	assert_eq(model.last_used(), &"power", "NONE never becomes the last-used one")
	assert_true(bool(model.toggle_last()["ok"]))
	assert_eq(model.active(), &"power", "A/B compare goes back to power")
	model.toggle_last()
	assert_eq(model.active(), OverlayModel.MODE_NONE)


func test_legend_carries_exactly_the_four_data_states() -> void:
	# C-64: these four ARE doc 11's 2-bit overlay_state, and SELECTED is not one.
	var model := _model()
	var rows := model.legend_rows()
	assert_eq(rows.size(), 4)
	var seen: Array[String] = []
	var cfg := _cfg()
	for row: Dictionary in rows:
		var state := String(row["state"])
		assert_false(seen.has(state))
		seen.append(state)
		assert_ne(str(row["glyph"]), "", "%s carries a glyph (A5)" % state)
		assert_true(cfg.has_string(str(row["label_key"])), "%s has copy" % state)
	assert_false(seen.has("selected"), "selection is a MarkerLayer ring, not a state")
	assert_almost_eq(UIConfig.get_num(rows[2], "pulse_hz", 0.0), 1.2, 0.0001,
			"CRITICAL pulses at 1.2 Hz")


func test_overlay_state_round_trips_and_never_resurrects_a_dead_overlay() -> void:
	var model := _model()
	model.select(&"power")
	var state := model.capture_state()
	assert_eq(str(state["overlay"]), "power")

	var restored := _model()
	restored.restore_state(state)
	assert_eq(restored.active(), &"power")
	assert_eq(restored.last_used(), &"power")

	# A save written when WATER was live must not bring it back once the system
	# has been pulled: the restore goes through the same enabled gate.
	var stale := _model()
	stale.restore_state({"overlay": "water", "overlay_last": "water"})
	assert_eq(stale.active(), OverlayModel.MODE_NONE)


# ===========================================================================
# OverlayRail — the Control half, in a live tree
# ===========================================================================

func test_rail_builds_a_chip_per_mode_with_a3_and_a15() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	assert_ne(rail, null, "SafeArea/HUDLayer/OverlayRail is wired")
	assert_false(rail.is_open(), "the strip starts down")
	var minimum := float(ThemeBuilder.touch_min_dp((mounted["root"] as UIRoot).config,
			1.0, false))
	for mode: StringName in rail.model.modes():
		var chip := rail.chip_button(mode)
		assert_ne(chip, null, "chip for %s" % mode)
		assert_true(chip.custom_minimum_size.x >= minimum, "%s is 48 dp wide" % mode)
		assert_true(chip.custom_minimum_size.y >= minimum, "%s is 48 dp tall" % mode)
		assert_ne(chip.tooltip_text, "", "%s has an A15 name" % mode)
	assert_ne(rail.rail_button().tooltip_text, "")
	_unmount(mounted)


func test_rail_button_raises_the_strip_and_a_chip_switches_the_overlay() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var changes: Array[StringName] = []
	rail.overlay_changed.connect(func(mode: StringName, _i: int) -> void:
		changes.append(mode))
	rail.rail_button().pressed.emit()
	assert_true(rail.is_open(), "one tap raises the strip")
	rail.chip_button(&"power").pressed.emit()
	assert_eq(rail.active_mode(), &"power")
	assert_eq(rail.active_index(), 1)
	assert_true(rail.is_open(), "the strip is sticky — the next overlay is one tap")
	assert_eq(changes, [&"power"] as Array[StringName])
	assert_true(rail.chip_button(&"power").text.contains(OverlayRail.CHECK_GLYPH),
			"the active chip carries a check glyph, not just a fill (A5)")
	_unmount(mounted)


func test_a_disabled_chip_answers_in_words_and_changes_nothing() -> void:
	# A14: "every blocked action states its reason in words".
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var refusals: Array[String] = []
	rail.overlay_refused.connect(func(_mode: StringName, message: String) -> void:
		refusals.append(message))
	rail.open()
	rail.chip_button(&"water").pressed.emit()
	assert_eq(rail.active_mode(), OverlayModel.MODE_NONE)
	assert_eq(refusals.size(), 1)
	assert_true(refusals[0].length() > 0, "the refusal is a sentence")
	assert_false(refusals[0].contains("{"), "no placeholder left unresolved")
	_unmount(mounted)


func test_rail_writes_doc11s_shader_global() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var global_name := StringName(rail.model.shader_global_name())
	assert_true(RenderingServer.global_shader_parameter_get_list().has(global_name),
			"project.godot declares %s" % global_name)
	rail.select(&"power")
	assert_eq(rail.active_index(), 1, "power is index 1 of overlay.modes")
	# The headless (dummy) rendering server accepts the write but does not read
	# values back, so the round-trip is only asserted where it is available.
	var readback: Variant = RenderingServer.global_shader_parameter_get(global_name)
	if readback is int or readback is float:
		assert_eq(int(readback), 1, "the global carries the mode index")
		rail.select(OverlayModel.MODE_NONE)
		assert_eq(int(RenderingServer.global_shader_parameter_get(global_name)), 0)
	_unmount(mounted)


func test_long_press_on_the_rail_button_does_not_also_toggle_the_strip() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	rail.select(&"power")
	rail.select(OverlayModel.MODE_NONE)
	var was_open := rail.is_open()
	rail.long_press()
	assert_eq(rail.active_mode(), &"power", "the hold restores the last overlay")
	assert_eq(rail.is_open(), was_open, "the hold is not also a tap")
	_unmount(mounted)
