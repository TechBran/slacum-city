extends SimTest
## Doc 12 §2.5 — the overlay rail: mutual exclusion, the enabled/disabled split
## while docs 05/06/10 are still landing, the `NONE ↔ last-used` long press, the
## four-state legend, and the `sc_overlay_mode` shader global doc 11 reads.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model() -> OverlayModel:
	return OverlayModel.new(_cfg())


## All six overlays are live as of Wave 5, so the A14 machinery that greys a mode
## whose system is not in the build has nothing left to grey in the shipped file.
## It is still a rule the console has to keep — pulling a system back out must
## stay a one-line data edit — so the refusal paths are exercised against a config
## whose `enabled_modes` has been trimmed, which is exactly the shape
## `data/ui.json` had before doc 06 published coverage.
func _cfg_without(modes: Array) -> UIConfig:
	var real := _cfg()
	var ui: Dictionary = real.ui_data().duplicate(true)
	var overlay: Dictionary = ui["overlay"]
	var kept: Array = []
	for value: Variant in (overlay["enabled_modes"] as Array):
		if not modes.has(StringName(str(value))):
			kept.append(value)
	overlay["enabled_modes"] = kept
	return UIConfig.new(ui, real.strings_data())


func _model_without(modes: Array) -> OverlayModel:
	return OverlayModel.new(_cfg_without(modes))


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


## A mounted rail driven by a config with those modes pulled from the build.
func _mount_without(modes: Array) -> Dictionary:
	var mounted := _mount()
	var cfg := _cfg_without(modes)
	(mounted["rail"] as OverlayRail).setup(cfg, OverlayModel.new(cfg))
	return mounted


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


func test_every_landed_system_is_live_and_a_pulled_one_explains_itself() -> void:
	var model := _model()
	assert_true(model.is_enabled(&"none"), "turning overlays off is never blocked")
	assert_true(model.is_enabled(&"power"), "doc 04 shipped")
	assert_true(model.is_enabled(&"water"), "doc 05 publishes service_factors()")
	assert_true(model.is_enabled(&"traffic"), "doc 10 publishes TrafficSnapshot")
	assert_true(model.is_enabled(&"police"), "doc 02 §2.9 publishes coverage_police")
	assert_true(model.is_enabled(&"fire"), "doc 02 §2.9 publishes coverage_fire")
	# A14: a mode pulled from the build stays listed with a reason in words — it
	# does not disappear, so the console never changes shape under the player.
	var trimmed := _model_without([&"police", &"fire"])
	for mode: StringName in [&"police", &"fire"]:
		assert_false(trimmed.is_enabled(mode), "%s is greyed, not gone" % mode)
		var chip_ids: Array[StringName] = []
		for chip: Dictionary in trimmed.chips():
			chip_ids.append(chip["id"])
		assert_true(chip_ids.has(mode), "%s is still on the strip" % mode)
	var cfg := _cfg()
	for chip: Dictionary in model.chips():
		assert_true(cfg.has_string(str(chip["label_key"])),
				"%s has copy" % chip["label_key"])
	assert_true(cfg.has_string("ui_overlay_disabled"))


func test_selection_is_mutually_exclusive_and_disabled_modes_are_refused() -> void:
	var model := _model_without([&"police"])
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

	# A save written when POLICE was live must not bring it back in a build that
	# has since pulled that system: the restore goes through the same gate.
	var stale := _model_without([&"police"])
	stale.restore_state({"overlay": "police", "overlay_last": "police"})
	assert_eq(stale.active(), OverlayModel.MODE_NONE)


func test_the_legend_collapse_is_per_overlay_and_rides_the_save() -> void:
	# §2.5: "Collapsible to a 32 dp pill; collapse state persists per overlay."
	# Per OVERLAY is the load-bearing half — folding the traffic legend away says
	# nothing about the power one.
	var model := _model()
	model.select(&"traffic")
	assert_false(model.is_legend_collapsed(), "a card opens expanded")
	assert_true(model.toggle_legend_collapsed())
	assert_true(model.is_legend_collapsed(&"traffic"))
	assert_false(model.is_legend_collapsed(&"power"), "power was never folded")
	model.set_legend_collapsed(OverlayModel.MODE_NONE, true)
	assert_false((model.capture_state()["overlay_collapsed"] as Array).has("none"),
			"`none` has no card, so it never enters the collapsed set")

	var restored := _model()
	restored.restore_state(model.capture_state())
	assert_true(restored.is_legend_collapsed(&"traffic"))
	assert_false(restored.is_legend_collapsed(&"water"))
	assert_eq(restored.active(), &"traffic")


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
	var mounted := _mount_without([&"police"])
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
	var mounted := _mount_without([&"fire"])
	var rail: OverlayRail = mounted["rail"]
	assert_true(bool(rail.select_mode(&"water")["ok"]))
	assert_eq(rail.active_mode(), &"water")
	assert_false(bool(rail.select_mode(&"fire")["ok"]), "a pulled system still refuses")
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


# ===========================================================================
# POLICE (3) / FIRE (4) — doc 02 §2.9's coverage field
# ===========================================================================

func test_coverage_with_no_requirement_bands_on_the_absolute_scalar() -> void:
	# Every L1 building's requirement rung is 0.00 (doc 02 §2.9's ladder), so the
	# only honest reading there is the raw scalar.
	var model := _model()
	assert_eq(model.coverage_state(0.00), RenderStateModel.OVERLAY_OFFLINE,
			"a lot no station reaches is OFFLINE, not a dark-red CRITICAL")
	assert_eq(model.coverage_state(0.20), RenderStateModel.OVERLAY_CRITICAL)
	assert_eq(model.coverage_state(0.50), RenderStateModel.OVERLAY_WARNING)
	assert_eq(model.coverage_state(0.95), RenderStateModel.OVERLAY_NORMAL)


func test_coverage_with_a_requirement_bands_on_the_margin() -> void:
	# Doc 02 §2.9's closing instruction: "The UI must show the margin, not just
	# pass/fail." The same 0.55 is a pass for a house and a failure for the L4
	# office next door, and the overlay has to say so.
	var model := _model()
	assert_eq(model.coverage_state(0.55, 0.60), RenderStateModel.OVERLAY_CRITICAL,
			"below its own requirement: upgrades blocked, safety penalty running")
	assert_eq(model.coverage_state(0.55, 0.00), RenderStateModel.OVERLAY_WARNING,
			"the same reading with nothing to satisfy is only a thin one")
	assert_eq(model.coverage_state(0.62, 0.60), RenderStateModel.OVERLAY_WARNING,
			"inside the margin — one dispatched engine from failing")
	assert_eq(model.coverage_state(0.95, 0.60), RenderStateModel.OVERLAY_NORMAL)
	assert_eq(model.coverage_state(0.0, 0.60), RenderStateModel.OVERLAY_OFFLINE,
			"no cover at all outranks the requirement band")


func test_the_e6_office_reads_normal_and_loses_it_with_its_engine() -> void:
	# The doc's own worked example, through the overlay: c = 0.627 against a 0.60
	# requirement passes by 0.027 — inside `coverage_margin_warn`, so the map
	# warns rather than telling the player everything is fine.
	var model := _model()
	assert_true(model.coverage_margin_warn() > 0.027,
			"E6's margin is inside the warn band, which is the point of it")
	assert_eq(model.coverage_state(0.627, 0.60), RenderStateModel.OVERLAY_WARNING)
	assert_eq(model.coverage_state(0.314, 0.60), RenderStateModel.OVERLAY_CRITICAL,
			"one engine away and the same lot is failing")


func test_coverage_states_takes_the_bulk_shape_the_shell_feeds() -> void:
	var model := _model()
	var states := model.coverage_states({
		11: {"coverage": 0.95, "requirement": 0.60},
		12: {"coverage": 0.10, "requirement": 0.60},
		13: 0.0,
	})
	assert_eq(states.size(), 3)
	assert_eq(int(states[11]), RenderStateModel.OVERLAY_NORMAL)
	assert_eq(int(states[12]), RenderStateModel.OVERLAY_CRITICAL)
	assert_eq(int(states[13]), RenderStateModel.OVERLAY_OFFLINE)


func test_the_coverage_legends_speak_margin_not_warning() -> void:
	var cfg := _cfg()
	var model := OverlayModel.new(cfg)
	for mode: StringName in [OverlayModel.MODE_POLICE, OverlayModel.MODE_FIRE]:
		var rows := model.legend_rows(mode)
		assert_eq(rows.size(), 4, "still exactly doc 11's four bits")
		for row: Dictionary in rows:
			assert_true(cfg.has_string(str(row["mode_label_key"])),
					"%s has coverage phrasing" % row["mode_label_key"])
			assert_ne(str(row["glyph"]), "", "%s carries its glyph (A5)" % row["state"])
	assert_eq(cfg.t(OverlayModel.state_label_key(OverlayModel.MODE_FIRE, "critical")),
			"Below requirement")


# ===========================================================================
# The OverlayLegend card (§2.5's top-left card)
# ===========================================================================

func test_the_legend_left_the_strip_for_its_own_card() -> void:
	# Report 98's last open item against §2.5: the strip is a control and closes,
	# which took the legend with it. The strip now carries chips and the refusal
	# notice; the reading lives on the card.
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var card := rail.legend_card()
	assert_ne(card, null, "the rail owns an OverlayLegend")
	assert_false(card.visible, "no overlay, no card")
	rail.select(&"police")
	assert_true(card.visible)
	assert_eq(card.mode(), &"police")
	assert_ne(rail.legend_row(&"normal"), null, "the four coverage rows are on it")
	var strip_legend := rail.get_node_or_null("Strip/Scroll/Body/Legend") as Control
	if strip_legend == null:
		strip_legend = rail.get_node_or_null("Strip/Body/Legend") as Control
	assert_ne(strip_legend, null, "the authored node is still there")
	assert_false(strip_legend.visible, "but the strip no longer draws a legend")
	assert_eq(strip_legend.get_child_count(), 0)
	rail.select(OverlayModel.MODE_NONE)
	assert_false(card.visible, "and it goes away with the overlay")
	_unmount(mounted)


func test_the_card_folds_to_a_pill_and_keeps_its_rows_out_of_the_way() -> void:
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	var card := rail.legend_card()
	var folded: Array[bool] = []
	rail.legend_collapsed.connect(func(_mode: StringName, value: bool) -> void:
		folded.append(value))
	rail.select(&"traffic")
	assert_false(card.is_collapsed())
	card.toggle_button().pressed.emit()
	assert_true(card.is_collapsed())
	assert_eq(folded.size(), 1, "the shell hears about it once, for the save")
	assert_eq(rail.legend_row(&"clear"), null, "a folded card draws no rows")
	# Per overlay: switching to another one comes up expanded.
	rail.select(&"water")
	assert_false(card.is_collapsed())
	rail.select(&"traffic")
	assert_true(card.is_collapsed(), "and traffic is still folded when you return")
	_unmount(mounted)


func test_the_card_prints_the_shells_aggregate_lines_and_no_more() -> void:
	# §2.5: "plus 1–3 overlay-specific aggregate lines".
	var mounted := _mount()
	var rail: OverlayRail = mounted["rail"]
	rail.select(&"fire")
	rail.set_summary_lines(&"fire", [
		{"label": "Stations", "value": "1"},
		{"label": "Lots with no cover", "value": "18", "state": "critical"},
		{"label": "Below requirement", "value": "3", "state": "warning"},
		{"label": "One line too many", "value": "-"},
	])
	assert_eq(rail.legend_card().summary_count(), 3,
			"the card is capped at legend_card.max_aggregate_lines")
	_unmount(mounted)


# ===========================================================================
# The colourblind palette reaches the CITY, not just the legend (A6)
# ===========================================================================

func test_the_building_tint_follows_the_same_palette_the_legend_does() -> void:
	var cfg := _cfg()
	var model := OverlayModel.new(cfg)
	var default_paint := model.building_state_paint()
	assert_eq(default_paint.size(), 4, "the four §2.5 states, no more")
	for state: String in OverlayModel.STATE_ORDER:
		assert_true(default_paint.has(state), "%s is painted" % state)
	# NORMAL deliberately does NOT take the palette's green — a city where every
	# healthy building glows is a city where nothing reads.
	assert_ne(str(Color(cfg.palette()["normal"])),
			str((default_paint["normal"] as Dictionary)["color"]),
			"NORMAL borrows a cool neutral, not the legend's green")
	assert_eq(str((default_paint["warning"] as Dictionary)["color"]),
			str(Color(str(cfg.palette()["warning"]))),
			"WARNING is exactly the hue the legend row is painted in")
	# And the variant moves it, which is the whole point.
	var deuteran := model.building_state_paint("deuteran")
	assert_ne(str((deuteran["critical"] as Dictionary)["color"]),
			str((default_paint["critical"] as Dictionary)["color"]),
			"a deuteran player gets a deuteran city, not a deuteran legend beside"
			+ " a trichromat one")
	var ordered := model.building_state_paint_ordered("deuteran")
	assert_eq(ordered.size(), 4, "doc 11's packing order, 0..3")
	assert_eq(str(ordered[2]["color"]), str((deuteran["critical"] as Dictionary)["color"]),
			"index 2 IS OVERLAY_CRITICAL")
