extends SimTest
## Doc 12 P1-30/P1-31: the data + scaffold half of the UI track — `data/ui.json`
## integrity against the §8 block, the string table conventions (G-8), the
## programmatic Theme (§4.3) and `UIRoot`'s headless layout/back-stack solvers
## (§2.1, §2.2). The HUD screens that hang off this land in P1-32.


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


# ---------------------------------------------------------------------------
# data/ui.json
# ---------------------------------------------------------------------------

func test_ui_json_sections_present() -> void:
	var cfg := _cfg()
	assert_true(cfg.is_valid(), "load errors: %s" % str(cfg.errors))
	for name: String in ["layout", "type_scale_dp", "palette", "overlay", "camera",
			"gestures_dp_ms", "placement", "thresholds", "speed", "away_report",
			"in_app_alerts", "haptics_ms", "defaults", "selection_ring"]:
		assert_false(cfg.section(name).is_empty(), "data/ui.json has section '%s'" % name)


func test_layout_constants_match_the_doc() -> void:
	var layout := _cfg().layout()
	assert_almost_eq(UIConfig.get_num(layout, "touch_target_min_dp", -1.0), 48.0, 0.0001, "A3")
	assert_almost_eq(UIConfig.get_num(layout, "touch_target_large_dp", -1.0), 56.0, 0.0001)
	assert_almost_eq(UIConfig.get_num(layout, "touch_spacing_min_dp", -1.0), 8.0, 0.0001, "A4")
	assert_almost_eq(UIConfig.get_num(layout, "top_bar_h_dp", -1.0), 48.0, 0.0001)
	assert_almost_eq(UIConfig.get_num(layout, "drawer_w_ratio", -1.0), 0.34, 0.0001)
	assert_eq(UIConfig.get_int(layout, "chip_never_hidden_count", -1), 4, "P1-P4 never hidden")
	var priority: Array = layout["chip_priority"]
	assert_eq(priority.size(), 7, "seven stat chips")
	assert_eq(priority[0], "treasury")
	assert_eq(priority[6], "stability")


func test_exactly_four_data_states_and_no_selected_member() -> void:
	# report 98 C-64: these four ARE doc 11's 2-bit overlay_state. SELECTED is a
	# MarkerLayer ring, not a fifth state, and never reaches the instance buffer.
	var ui := _cfg().ui_data()
	for key: String in ["state_glyphs", "state_dash", "state_pulse_hz"]:
		var block: Dictionary = ui[key]
		assert_eq(block.size(), 4, "%s has exactly four keys" % key)
		for state: String in ["normal", "warning", "critical", "offline"]:
			assert_true(block.has(state), "%s carries %s" % [key, state])
		assert_false(block.has("selected"), "%s must not carry a 'selected' member" % key)
	var ring: Dictionary = ui["selection_ring"]
	assert_eq(str(ring["color_token"]), "selected")
	assert_eq(str(ring["layer"]), "MarkerLayer")
	assert_false(bool(ring["is_overlay_state"]))
	assert_eq(UIConfig.get_int(ring, "max_concurrent", -1), 1, "selection is single-valued")


func test_state_glyphs_and_dash_patterns_are_unique() -> void:
	# A5: colour is never load-bearing — every state carries a distinct glyph and
	# a distinct dash pattern, identical across every colourblind variant.
	var ui := _cfg().ui_data()
	var glyphs: Array = (ui["state_glyphs"] as Dictionary).values()
	var seen: Array = []
	for glyph: String in glyphs:
		assert_false(seen.has(glyph), "glyph '%s' is unique" % glyph)
		seen.append(glyph)
	var dashes: Array = (ui["state_dash"] as Dictionary).values()
	var seen_dash: Array = []
	for dash: Array in dashes:
		assert_false(seen_dash.has(dash), "dash pattern %s is unique" % str(dash))
		seen_dash.append(dash)


func test_colourblind_variants_swap_hex_only() -> void:
	var cfg := _cfg()
	var base := cfg.palette("default")
	for variant: String in ["deuteran", "protan", "tritan"]:
		var merged := cfg.palette(variant)
		assert_eq(merged.size(), base.size(), "%s inherits every default token" % variant)
		for token: String in merged:
			var value := str(merged[token])
			assert_true(Color.html_is_valid(value), "%s.%s is a hex colour" % [variant, token])
		assert_ne(str(merged["normal"]), str(base["normal"]), "%s remaps NORMAL" % variant)
		assert_eq(str(merged["bg"]), str(base["bg"]), "%s keeps the chrome tokens" % variant)


func test_in_app_alert_budgets_never_touch_push() -> void:
	# report 98 C-71/C-72: this block is FOREGROUND only and is ~3x doc 08's push
	# budgets on purpose. Any code path reading one to decide the other is a bug.
	var gate := _cfg().section("in_app_alerts")
	assert_false(bool(gate["may_emit_push"]), "the in-app gate never pushes")
	assert_false(bool(gate["consults_quiet_hours"]), "quiet hours are a push concern")
	assert_eq(UIConfig.get_int(gate, "global_max_per_hour", -1), 3)
	assert_eq(str(gate["global_applies_to"]), str(["p2", "p3"]), "P1 is exempt")
	assert_eq(UIConfig.get_int(gate, "per_type_cooldown_s", -1), 600)
	var classes: Dictionary = gate["classes"]
	assert_eq(classes.size(), 3, "P1-P3; P4 ships disabled and is doc 08's")
	assert_eq(UIConfig.get_int(classes["p1"], "refill_per_real_hour", -1), 6)
	assert_eq(UIConfig.get_int(classes["p2"], "refill_per_real_hour", -1), 3)
	assert_eq(UIConfig.get_int(classes["p3"], "refill_per_real_hour", -1), 1)
	assert_true(bool((classes["p1"] as Dictionary)["never_drop"]))
	assert_true(bool((classes["p1"] as Dictionary)["exempt_from_global"]))
	assert_eq(UIConfig.get_int(classes["p1"], "coalesce_window_s", -1), 300)
	assert_eq(str(gate["class_map_from"]), "data/notifications.json", "doc 08 owns the map")
	# The deleted push block must not have crept back in (C-71).
	var ui := _cfg().ui_data()
	assert_false(ui.has("notifications"), "push policy is doc 08's data/notifications.json")
	assert_false(ui.has("quiet_hours_default"))
	assert_false(ui.has("event_priority"))


func test_speed_options_follow_doc01() -> void:
	var speed := _cfg().section("speed")
	var options: Array = speed["options"]
	assert_eq(options.size(), 3, "doc 01 locks speed in {1,2,3}")
	assert_eq(int(options[0]), 1)
	assert_eq(int(options[1]), 2)
	assert_eq(int(options[2]), 3)
	assert_eq(UIConfig.get_int(speed, "default", -1), 1)
	assert_true(bool(speed["paused_is_separate_flag"]))
	assert_true(bool(speed["resume_unpaused"]))


# ---------------------------------------------------------------------------
# data/strings.en.json (G-8)
# ---------------------------------------------------------------------------

func test_string_table_key_conventions() -> void:
	var cfg := _cfg()
	var table := cfg.strings_data()
	var key_re := RegEx.new()
	# `_one` / `_plural` are the two plural satellites of doc 12 delta D-10; they
	# hang off a base key rather than naming a screen element of their own.
	key_re.compile("^(ui_[a-z0-9_]+|n_[a-z0-9_]+_(title|body)(_one|_plural)?)$")
	var ui_keys := 0
	for key: String in table:
		if key.begins_with("_") or key == "schema_version":
			continue
		assert_true(key_re.search(key) != null, "key '%s' matches the G-8 convention" % key)
		var value := str(table[key])
		assert_false(value.contains("%s"), "'%s' uses {named} placeholders, never %%s" % key)
		ui_keys += 1
	assert_true(ui_keys >= 30, "the seed table carries the load-bearing templates")


func test_requirement_templates_cover_all_thirteen_codes() -> void:
	# report 98 C-62: 13 failure codes, each resolving copy from
	# ui_requirement_<code_lowercase> so the sim never returns a display string.
	var cfg := _cfg()
	var codes := ["POWER_CAPACITY", "WATER_PRESSURE", "NO_ROAD", "NO_CREW", "FIRE_COVERAGE",
			"CITY_LEVEL", "FUNDS", "OCCUPIED", "NOT_OWNED", "UNDEVELOPED", "TERRAIN",
			"TECH_LOCK", "E_AVENUE"]
	assert_eq(codes.size(), 13)
	for code: String in codes:
		var key := "ui_requirement_" + code.to_lower()
		assert_true(cfg.has_string(key), "data/strings.en.json carries %s" % key)
	# E_AVENUE keeps doc 02's check name verbatim and names the target level.
	var avenue := cfg.t("ui_requirement_e_avenue", {"have": 7, "need": 4, "level": 4})
	assert_true(avenue.contains("7") and avenue.contains("4"), "have/need substituted")
	assert_false(avenue.contains("{"), "no placeholder left unresolved")
	assert_true(avenue.contains("AVENUE"), "names the fix")


func test_string_lookup_and_missing_key_behaviour() -> void:
	var cfg := _cfg()
	assert_eq(cfg.t("ui_build_open"), "BUILD")
	assert_eq(cfg.t("ui_drawer_count", {"n": 2}), "2 active")
	assert_eq(cfg.t("ui_drawer_held"), "HELD")
	# A missing key returns the key itself (never a silent blank) — doc 12 test 21
	# turns that into a build failure once every screen is authored.
	assert_eq(cfg.t("ui_does_not_exist"), "ui_does_not_exist")
	assert_false(cfg.has_string("ui_does_not_exist"))


# ---------------------------------------------------------------------------
# Theme (doc 12 §4.3)
# ---------------------------------------------------------------------------

func test_theme_builds_from_data() -> void:
	var cfg := _cfg()
	var theme := ThemeBuilder.build(cfg)
	assert_ne(theme, null)
	assert_eq(theme.default_font_size, 14, "base font 14 dp")
	for name: String in ThemeBuilder.TYPE_VARIATIONS:
		assert_eq(str(theme.get_type_variation_base(name)),
				str(ThemeBuilder.TYPE_VARIATIONS[name]), "%s variation is registered" % name)
	assert_eq(theme.get_font_size("font_size", "StatChip"), 16, "numeric type scale")
	assert_eq(theme.get_font_size("font_size", "TabButton"), 12, "label type scale")
	# Palette tokens are generated at boot, not hand-authored into the .tres.
	assert_true(theme.has_color("critical", ThemeBuilder.PALETTE_TYPE))
	assert_eq(theme.get_color("critical", ThemeBuilder.PALETTE_TYPE), Color.html("#E5533D"))
	assert_eq(theme.get_color("normal", ThemeBuilder.PALETTE_TYPE), Color.html("#33C27A"))
	assert_eq(theme.get_color("selected", ThemeBuilder.PALETTE_TYPE), Color.html("#4FA8FF"))


func test_theme_colourblind_variant_swaps_only_state_hues() -> void:
	var cfg := _cfg()
	var base := ThemeBuilder.build(cfg)
	var deuteran := ThemeBuilder.build(cfg, {"colorblind": "deuteran"})
	assert_ne(deuteran.get_color("normal", ThemeBuilder.PALETTE_TYPE),
			base.get_color("normal", ThemeBuilder.PALETTE_TYPE))
	assert_eq(deuteran.get_color("bg", ThemeBuilder.PALETTE_TYPE),
			base.get_color("bg", ThemeBuilder.PALETTE_TYPE))


func test_touch_minimums_never_shrink() -> void:
	var cfg := _cfg()
	assert_eq(ThemeBuilder.touch_min_dp(cfg, 1.0, false), 48, "A3 floor")
	assert_eq(ThemeBuilder.touch_min_dp(cfg, 1.0, true), 56, "larger_touch_targets")
	assert_eq(ThemeBuilder.touch_min_dp(cfg, 1.5, false), 72, "ceil(48 * 1.5)")
	assert_eq(ThemeBuilder.touch_min_dp(cfg, 1.15, false), 56, "ceil(48 * 1.15) = 56")
	assert_eq(ThemeBuilder.touch_min_dp(cfg, 0.85, false), 48,
			"text scale below 1 never shrinks a touch target")
	assert_eq(ThemeBuilder.min_touch_size(cfg, 1.0, false), Vector2(48.0, 48.0))


func test_theme_scaler_multiplies_font_sizes() -> void:
	var cfg := _cfg()
	var base := ThemeBuilder.build(cfg)
	var scaled := ThemeBuilder.scale_theme(base, 1.5)
	assert_eq(scaled.default_font_size, 21, "14 * 1.5 rounded to whole dp")
	assert_eq(scaled.get_font_size("font_size", "StatChip"), 24, "16 * 1.5")
	assert_eq(base.default_font_size, 14, "the base theme is not mutated")
	# The same path is taken when text_scale arrives through build().
	var built := ThemeBuilder.build(cfg, {"text_scale": 1.5})
	assert_eq(built.default_font_size, 21)


func test_a_button_stylebox_is_scaled_exactly_once() -> void:
	# **The accessibility root defect, as one assertion.** `build()` used to size
	# a button's vertical padding from an ALREADY-SCALED touch minimum and then
	# hand the theme to `scale_theme()`, which scales every content margin again —
	# so a 56 dp target at 130 % measured 100 dp against a 73 dp requirement, and
	# every A2/A3 finding in the Wave-12 sweep was that number arriving somewhere
	# it did not fit. The padding is now derived at 1.0 and scaled once.
	var cfg := _cfg()
	var body := int(UIConfig.get_num(cfg.section("type_scale_dp"), "body", 14.0))
	for arm: Array in [[1.3, true], [1.5, true], [1.3, false], [1.5, false]]:
		var scale: float = arm[0]
		var larger: bool = arm[1]
		var scaled := ThemeBuilder.build(cfg,
				{"text_scale": scale, "larger_touch_targets": larger})
		var base := ThemeBuilder.build(cfg, {"larger_touch_targets": larger})
		for type_name: String in ["Button", "StatChip", "RailButton", "PrimaryFAB"]:
			var one := base.get_stylebox("normal", type_name)
			var two := scaled.get_stylebox("normal", type_name)
			assert_almost_eq(two.content_margin_top,
					round(one.content_margin_top * scale), 0.001,
					"%s at %d %% is its own padding × the scale, once"
					% [type_name, int(scale * 100.0)])
		# And the whole point: what the theme alone makes a button measure still
		# clears A3's floor without overshooting it into the next control.
		var floor_dp := float(ThemeBuilder.touch_min_dp(cfg, scale, larger))
		var box := scaled.get_stylebox("normal", "StatChip")
		var themed_h := box.content_margin_top + box.content_margin_bottom \
				+ float(body) * scale * 1.4
		# Rounding slack, not a second multiplication: `ceil` on the padding and
		# `round` on the scaled margin can each add a dp, and 4 dp is the whole
		# budget for both. A second scaling costs 22 dp at 130 % and 32 at 150 %.
		assert_true(themed_h <= floor_dp + 4.0,
				"a StatChip's own box is %d dp against an A3 floor of %d"
				% [int(themed_h), int(floor_dp)])


func test_the_stylebox_fix_is_a_no_op_at_100_percent() -> void:
	# The reference layout may not move: every screenshot in the repository is at
	# 100 % text with 48 dp targets, and a root fix that shifted one dp there
	# would be a redesign wearing a bug fix's clothes.
	var cfg := _cfg()
	for larger: bool in [false, true]:
		var theme := ThemeBuilder.build(cfg, {"larger_touch_targets": larger})
		var box := theme.get_stylebox("normal", "StatChip")
		var expected := maxf(4.0, ceil((float(ThemeBuilder.touch_min_dp(cfg, 1.0, larger))
				- float(UIConfig.get_num(cfg.section("type_scale_dp"), "body", 14.0))
						* 1.4) * 0.5))
		assert_almost_eq(box.content_margin_top, expected, 0.001)


func test_text_scale_options_are_the_five_the_doc_lists() -> void:
	var ui := _cfg().ui_data()
	assert_eq(str(ui["text_scale_options"]), str([0.85, 1.0, 1.15, 1.30, 1.50]), "A2")


# ---------------------------------------------------------------------------
# UIRoot solvers (doc 12 §2.1, §2.2)
# ---------------------------------------------------------------------------

func test_breakpoints() -> void:
	var layout := _cfg().layout()
	assert_eq(UIRoot.breakpoint_for(640.0, layout), UIRoot.Breakpoint.COMPACT)
	assert_eq(UIRoot.breakpoint_for(699.0, layout), UIRoot.Breakpoint.COMPACT)
	assert_eq(UIRoot.breakpoint_for(700.0, layout), UIRoot.Breakpoint.REGULAR)
	assert_eq(UIRoot.breakpoint_for(880.0, layout), UIRoot.Breakpoint.REGULAR, "reference box")
	assert_eq(UIRoot.breakpoint_for(899.0, layout), UIRoot.Breakpoint.REGULAR)
	assert_eq(UIRoot.breakpoint_for(900.0, layout), UIRoot.Breakpoint.WIDE)


func test_drawer_width_formula() -> void:
	# drawer_w = clamp(round(0.34 * W), 260, 340)
	var layout := _cfg().layout()
	assert_eq(UIRoot.drawer_width_dp(640.0, layout), 260, "0.34*640 = 217.6 -> floor 260")
	assert_eq(UIRoot.drawer_width_dp(880.0, layout), 299, "0.34*880 = 299.2 -> 299")
	assert_eq(UIRoot.drawer_width_dp(1000.0, layout), 340, "0.34*1000 = 340")
	assert_eq(UIRoot.drawer_width_dp(1400.0, layout), 340, "clamped at the ceiling")


func test_back_stack_order() -> void:
	# ModalLayer -> SheetLayer -> PanelLayer -> placement cancel -> deselect ->
	# "press back again to minimise". S0 is the one context that REMOVES rungs
	# rather than adding one (`tests/test_ui_title.gd` holds that half); with the
	# door shut the order below is doc 12 §2.2's, unchanged.
	var ctx := {"modal_open": true, "title_open": false, "sheet_open": true,
			"panel_open": true, "placement_active": true, "has_selection": true,
			"back_pressed_recently": true}
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_CLOSE_MODAL)
	ctx["modal_open"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_CLOSE_SHEET)
	ctx["sheet_open"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_CLOSE_PANEL)
	ctx["panel_open"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_CANCEL_PLACEMENT)
	ctx["placement_active"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_DESELECT)
	ctx["has_selection"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_MINIMISE, "second press within 2 s")
	ctx["back_pressed_recently"] = false
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_PROMPT_MINIMISE, "first press prompts")


# ---------------------------------------------------------------------------
# The scaffold scene
# ---------------------------------------------------------------------------

func test_ui_root_scene_structure() -> void:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	assert_ne(packed, null, "game/ui/ui_root.tscn loads")
	var root: Node = packed.instantiate()
	assert_true(root is CanvasLayer)
	assert_eq((root as CanvasLayer).layer, UIRoot.CANVAS_LAYER_UI)
	for path: String in ["SafeArea", "SafeArea/MarkerLayer", "SafeArea/HUDLayer",
			"SafeArea/HUDLayer/TopBar", "SafeArea/HUDLayer/LeftRail",
			"SafeArea/HUDLayer/RightRail", "SafeArea/HUDLayer/AlertStack",
			"SafeArea/PanelLayer", "SafeArea/SheetLayer", "SafeArea/TitleLayer",
			"SafeArea/TitleLayer/TitleScreen", "SafeArea/ModalLayer",
			"SafeArea/CoachLayer", "ToastLayer"]:
		assert_ne(root.get_node_or_null(path), null, "scaffold has %s" % path)
	assert_true(root.get_node("SafeArea") is MarginContainer)
	assert_eq((root.get_node("ToastLayer") as CanvasLayer).layer, UIRoot.CANVAS_LAYER_TOAST)
	# Containers must not eat touches, or nothing reaches the camera.
	for path: String in ["SafeArea/HUDLayer", "SafeArea/PanelLayer", "SafeArea/SheetLayer",
			"SafeArea/TitleLayer", "SafeArea/ModalLayer", "SafeArea/CoachLayer"]:
		assert_eq((root.get_node(path) as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE,
				"%s is IGNORE" % path)
	assert_eq((root.get_node("SafeArea/MarkerLayer") as Control).mouse_filter,
			Control.MOUSE_FILTER_PASS, "MarkerLayer passes touches through to the camera")
	root.free()
