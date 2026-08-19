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


func test_only_the_landed_systems_are_live_and_the_rest_explain_themselves() -> void:
	var model := _model()
	assert_true(model.is_enabled(&"none"), "turning overlays off is never blocked")
	assert_true(model.is_enabled(&"power"), "doc 04 shipped")
	assert_true(model.is_enabled(&"water"), "doc 05 publishes service_factors()")
	assert_true(model.is_enabled(&"traffic"), "doc 10 publishes TrafficSnapshot")
	for mode: StringName in [&"police", &"fire"]:
		assert_false(model.is_enabled(mode), "%s has no coverage query yet" % mode)
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

	var police := model.select(&"police")
	assert_false(bool(police["ok"]))
	assert_eq(police["reason"], OverlayModel.REASON_DISABLED)
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

	# A save written when POLICE was live must not bring it back before that
	# system lands: the restore goes through the same enabled gate.
	var stale := _model()
	stale.restore_state({"overlay": "police", "overlay_last": "police"})
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
	rail.chip_button(&"police").pressed.emit()
	assert_eq(rail.active_mode(), OverlayModel.MODE_NONE)
	assert_eq(refusals.size(), 1)
	assert_true(refusals[0].length() > 0, "the refusal is a sentence")
	assert_false(refusals[0].contains("{"), "no placeholder left unresolved")
	_unmount(mounted)


func test_rail_writes_doc11s_shader_global() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var global_name := StringName(rail.model.shader_global_name())
	# NOT `global_shader_parameter_get_list()`: that call is editor-only and
	# returns an empty Array in a game build, which is exactly the trap the rail
	# used to guard its write with (see `_write_shader_global`). project.godot is
	# the declaration, so the declaration is asserted against project.godot.
	var project := ConfigFile.new()
	assert_eq(project.load("res://project.godot"), OK)
	assert_true(project.has_section_key("shader_globals", String(global_name)),
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


func test_select_mode_is_the_deeplink_alias() -> void:
	# §2.10's dashboard rows emit `overlay/<mode>` and the shell forwards it as
	# `select_mode`. Same path, same verdict — a deep link is not a second rule.
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	assert_true(bool(rail.select_mode(&"water")["ok"]))
	assert_eq(rail.active_mode(), &"water")
	assert_false(bool(rail.select_mode(&"fire")["ok"]), "a dead system still refuses")
	assert_eq(rail.active_mode(), &"water")
	_unmount(mounted)


# ===========================================================================
# WATER (mode 2) — doc 05's per-building factor → doc 11's 2 bits
# ===========================================================================

func test_water_bands_map_a_service_factor_onto_the_four_data_states() -> void:
	var model := _model()
	# The four §2.5 states, in doc 11's packing order: this IS what gets written
	# into `overlay_state` while mode 2 is live.
	assert_eq(model.water_state(0.00), RenderStateModel.OVERLAY_OFFLINE,
			"no water at all is OFFLINE, not a dark red CRITICAL")
	assert_eq(model.water_state(0.20), RenderStateModel.OVERLAY_CRITICAL)
	assert_eq(model.water_state(0.60), RenderStateModel.OVERLAY_WARNING)
	assert_eq(model.water_state(1.00), RenderStateModel.OVERLAY_NORMAL)
	assert_eq(model.water_state(-5.0), RenderStateModel.OVERLAY_OFFLINE,
			"out of range clamps rather than falling off the ladder")
	assert_eq(model.water_state(9.0), RenderStateModel.OVERLAY_NORMAL)
	# The band edges are ordered, so the ladder is monotone: a wetter building
	# is never in a worse state than a drier one.
	var previous := 4
	for i in 21:
		var state := model.water_state(float(i) / 20.0)
		assert_true(state <= previous, "water state is monotone at %f" % (float(i) / 20.0))
		previous = state


func test_water_states_is_the_bulk_form_the_shell_feeds() -> void:
	var model := _model()
	var states := model.water_states({"R1": 1.0, "R2": 0.5, "R3": 0.0})
	assert_eq(states.size(), 3)
	assert_eq(int(states["R1"]), RenderStateModel.OVERLAY_NORMAL)
	assert_eq(int(states["R2"]), RenderStateModel.OVERLAY_WARNING)
	assert_eq(int(states["R3"]), RenderStateModel.OVERLAY_OFFLINE)


func test_the_water_legend_speaks_water_not_warning() -> void:
	var cfg := _cfg()
	var model := OverlayModel.new(cfg)
	var rows := model.legend_rows(OverlayModel.MODE_WATER)
	assert_eq(rows.size(), 4, "still exactly doc 11's four bits, never a fifth")
	for row: Dictionary in rows:
		assert_true(cfg.has_string(str(row["mode_label_key"])),
				"%s has water phrasing" % row["mode_label_key"])
		assert_ne(str(row["glyph"]), "", "%s still carries its glyph (A5)" % row["state"])
	assert_eq(str(rows[0]["mode_label_key"]), "ui_overlay_water_normal")
	# POWER has no bespoke phrasing, so it falls back to the generic words.
	var power_rows := model.legend_rows(OverlayModel.MODE_POWER)
	assert_eq(str(power_rows[0]["mode_label_key"]), "ui_overlay_state_normal")


# ===========================================================================
# TRAFFIC (mode 5) — doc 10's per-edge congestion index
# ===========================================================================

func test_traffic_bands_are_the_same_cut_points_the_sim_uses() -> void:
	# doc 10 §2.15's ladder lives in `RoadCosts.overlay_band`; the overlay's copy
	# of it lives in data/ui.json so the legend can print it. They are the same
	# ladder or the legend lies — this is the test that keeps them one.
	var model := _model()
	for i in 101:
		var c := float(i) / 100.0
		assert_eq(model.traffic_band(c), RoadCosts.overlay_band(c),
				"congestion %f classifies the same in both tables" % c)
	assert_eq(model.traffic_band(1.4), &"gridlock", "past the top is still gridlock")


func test_traffic_band_rows_carry_a_second_channel_besides_colour() -> void:
	# Constitution §11 / spec §49: colour is never load-bearing. The alpha ramp
	# and the hatch duty both have to rise with congestion, and the two bands
	# that mean STOP have to move.
	var model := _model()
	var previous_alpha := -1.0
	var previous_duty := -1.0
	var moving := 0
	for row: Dictionary in model.traffic_legend_rows():
		var paint := model.traffic_band_row(row["band"])
		assert_true(float(paint["alpha"]) > previous_alpha,
				"%s is denser than the band below it" % row["band"])
		assert_true(float(paint["stripe_duty"]) >= previous_duty,
				"%s hatches at least as hard as the band below it" % row["band"])
		assert_ne(str(row["glyph"]), "", "%s carries a glyph" % row["band"])
		previous_alpha = float(paint["alpha"])
		previous_duty = float(paint["stripe_duty"])
		if float(paint["pulse_hz"]) > 0.0:
			moving += 1
	assert_eq(moving, 2, "severe and gridlock move; the calmer three hold still")


func test_the_legend_follows_the_active_overlay() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	assert_eq(rail.legend_mode(), OverlayModel.MODE_NONE)
	rail.select(&"traffic")
	assert_eq(rail.legend_mode(), &"traffic")
	for band: StringName in [&"clear", &"light", &"heavy", &"severe", &"gridlock"]:
		var line := rail.legend_row(band)
		assert_ne(line, null, "the traffic legend lists %s" % band)
		assert_ne(line.text.strip_edges(), "", "%s reads as words" % band)
	assert_eq(rail.legend_row(&"normal"), null,
			"and the four data states are NOT on screen under a band legend")
	rail.select(&"water")
	assert_eq(rail.legend_mode(), &"water")
	assert_ne(rail.legend_row(&"normal"), null, "water is back on the four states")
	assert_true(rail.legend_row(&"normal").text.contains(
			(mounted["root"] as UIRoot).config.t("ui_overlay_water_normal")),
			"and it says `Full pressure`, not `Normal`")
	_unmount(mounted)
