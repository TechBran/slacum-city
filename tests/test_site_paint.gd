extends SimTest
## **Wave 30 — the ghost paints where a source can legally go** (doc 12 D-130 /
## D-131, doc 93 §BG1, doc 11 §2.20, closing doc 91 `A91-D-162`/`A91-D-163`/
## `A91-D-164`).
##
## Wave 28 shipped the read and the sentence. `BuildController.placement_sites()`
## runs the ghost's own preflight over a window and hands back **verified legal
## origins**; `ui/build_sheet.gd` prints *"3 spots for this within 10 tiles — the
## nearest is 3 tiles away, $38.1K"*. Nothing painted the tiles: `site_hint()`
## `["tiles"]` was an `Array[Vector2i]` that no file in `game/` ever read, which
## is `A91-D-19`'s shape — a correct, tested, authored answer with no consumer.
##
## Everything in this file is about the five properties that make the paint an
## ANSWER rather than a decoration:
##
##   1. it is the same window the sentence was written from;
##   2. it is lit exactly when that sentence is printed;
##   3. a tap on a lit tile lands the ghost on the origin that was verified —
##      which is arithmetic, and wrong by one tile for every footprint bigger
##      than 1×1 if the paint goes on the origin instead of the anchor;
##   4. a site the window WARNS about wears the warning glyph, not the clean one
##      (doc 93 §BD9 — legal, and not the one to recommend);
##   5. it costs one draw call lit, none at rest, and never a re-scan per frame.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


## The founding city's shoreline window — where a river intake actually has an
## answer. Measured, not guessed: `placement_sites()` from the plant answers
## `ui_site_no_shoreline` and carries the nearest water as its `fix_target`, so
## this is the tile the bar's own door sends the camera to.
const SHORE := Vector2i(38, 51)


## The ghost, standing on `tile`, with the sheet's bar refreshed — the state the
## shell is in every time it calls `site_paint()`.
static func _stand(sheet: BuildSheet, controller: BuildController,
		tile: Vector2i) -> void:
	sheet.move_ghost(Vector3((float(tile.x) + 0.5) * controller.tile_m, 0.0,
			(float(tile.y) + 0.5) * controller.tile_m))


# ===========================================================================
# 1. ONE WINDOW — the sentence and the ground cannot disagree
# ===========================================================================

func test_the_ground_lights_the_window_the_bar_spoke_about() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter_water_component("source")["ok"]))
	_stand(root.build_sheet, controller, SHORE)

	var hint := root.build_sheet.site_hint()
	var paint := root.build_sheet.site_paint()
	assert_true(bool(paint["visible"]), "a refused intake on the shore has an answer")
	assert_eq(paint["centre"], hint["centre"], "the same window centre")
	assert_eq(int(paint["radius"]), int(hint["radius"]), "the same radius")
	assert_eq(int(paint["count"]), int(hint["count"]), "the same count")
	assert_eq(paint["nearest"], hint["nearest"], "the same nearest")
	# …and the same SET, in the same order.
	var painted: Array = []
	for raw: Variant in (paint["tiles"] as Array):
		painted.append((raw as Dictionary)["origin"])
	assert_eq(painted, hint["tiles"] as Array,
			"the ground draws the window's own origins, not a second search")
	# The measurement this file is the guard for.
	assert_eq(int(hint["count"]), 3, "three intakes on the founding city's shore")
	assert_eq(hint["nearest"], Vector2i(35, 49))
	assert_eq(int(hint["cost"]), 38086, "…and the nearest costs $38,086")
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_the_ground_is_lit_exactly_when_the_bar_says_where() -> void:
	# Requirement (2) of D-130 as a property rather than as a hope: the paint
	# rides `_site_hint_spoken`, which is set by the ONE line of `_refresh_bar`
	# that prints the window's sentence.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter("house")["ok"]))

	# A tile the ghost accepts: no refusal, so no sentence and no paint.
	var good := _first_legal(controller)
	assert_ne(good, Vector2i(-1, -1), "the founding city has somewhere to put a house")
	_stand(root.build_sheet, controller, good)
	assert_false(bool(root.build_sheet.site_paint()["visible"]),
			"a ghost that is not refused is not asking where else")

	# A tile it refuses, inside a window that HAS an answer.
	var bad := _first_blocked_near(controller, good)
	assert_ne(bad, Vector2i(-1, -1))
	_stand(root.build_sheet, controller, bad)
	var sentence := root.build_sheet.placement_issue_text()
	var paint := root.build_sheet.site_paint()
	assert_true(bool(paint["visible"]), "refused, and the window found spots")
	assert_true(sentence.contains("spot"),
			"…so the bar said so in words too: %s" % sentence)
	# And the count in the sentence is the count the ground is a picture of.
	assert_true(sentence.contains(str(int(paint["count"]))),
			"the sentence's number is the window's: %s" % sentence)
	root.build_sheet.cancel_placement()
	assert_false(bool(root.build_sheet.site_paint()["visible"]),
			"placement over, ground clean")
	_unmount(root)


func test_a_run_tool_paints_no_sites_because_a_run_has_no_origin() -> void:
	# `site_hint()` already declines while a path tool is up (a run is a stroke,
	# not a footprint). The paint has to decline with it rather than redrawing
	# the last box card's answer under a road.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	root.build_sheet.open()
	root.build_sheet.select_category(PathTool.CATEGORY_ROADS)
	root.build_sheet.card_button("road_street").pressed.emit()
	assert_true(root.build_sheet.is_placing_path(), "a run tool is up")
	assert_true(root.build_sheet.site_hint().is_empty(),
			"a stroke is not a footprint, so there is no window to ask about")
	assert_false(bool(root.build_sheet.site_paint()["visible"]),
			"…and nothing on the ground pretending there is")
	root.build_sheet.cancel_placement()
	_unmount(root)


# ===========================================================================
# 2. THE DOOR THE PAINT IMPLIES — a tap on a lit tile
# ===========================================================================

func test_a_tap_on_a_lit_tile_lands_the_ghost_on_the_site_that_was_verified() -> void:
	# **The arithmetic that makes the paint honest.** The shell's tap path is
	# `BuildSheet.move_ghost` → `BuildController.move_to_ground`, which CENTRES
	# the footprint: `origin_for_ground(p) = tile_at(p) − centre_offset()`. Paint
	# a 3×3's ORIGIN and the tap that follows the paint lands the ghost one tile
	# up-left of the verified site. So the paint goes on the ANCHOR, and this is
	# the round trip, on a 1×1, a 2×2 and a 3×3.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	var sizes: Dictionary = {}
	for card: String in ["house", "store", "construction_yard"]:
		if not bool(controller.enter(card)["ok"]):
			continue
		var lot: Vector2i = controller.size
		var hint := controller.placement_sites(Vector2i(40, 40))
		var offset := controller.centre_offset()
		sizes[lot] = true
		var model := SitePaintModel.new(root.config)
		var paint := model.paint(hint, controller.ghost(), offset, controller.tile_m)
		var rows: Array = paint["tiles"] as Array
		assert_true(not rows.is_empty(), "%s has somewhere to go" % card)
		for raw: Variant in rows:
			var row: Dictionary = raw
			assert_eq(row["anchor"], (row["origin"] as Vector2i) + offset,
					"the lit tile is the origin plus the footprint's own centring")
			# The tap, through the shell's own call.
			_stand(root.build_sheet, controller, row["anchor"])
			assert_eq(controller.origin, row["origin"],
					"%s %s: a tap on the lit tile puts the ghost on the site"
					% [card, str(lot)])
			assert_ne(String(controller.verdict()["verdict"]),
					String(BuildController.VERDICT_BLOCKED),
					"…and the site the paint promised is one the ghost takes")
		controller.cancel()
	assert_true(sizes.has(Vector2i(1, 1)) and sizes.has(Vector2i(2, 2))
			and sizes.has(Vector2i(3, 3)),
			"all three footprint parities were exercised: %s" % str(sizes.keys()))
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_the_anchor_is_the_exact_inverse_of_the_shells_own_tile_maths() -> void:
	# The identity, without a city: `origin_for_ground` subtracts the centring
	# offset from the tile under the finger, so the tile that produces `origin`
	# is `origin + offset`. Stated once, here, so the day either half moves the
	# other one fails.
	for size in [Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3), Vector2i(4, 4)]:
		var offset := Vector2i((size.x - 1) / 2, (size.y - 1) / 2)
		for origin in [Vector2i(0, 0), Vector2i(7, 3), Vector2i(61, 44)]:
			var anchor := SitePaintModel.anchor_of(origin, offset)
			assert_eq(anchor - offset, origin,
					"%s at %s round trips" % [str(size), str(origin)])


# ===========================================================================
# 3. THE MARKS — the legend's vocabulary, never a fifth glyph
# ===========================================================================

func test_a_clean_site_wears_the_normal_mark_and_a_warned_one_the_warning_mark() -> void:
	# `placement_sites` sorts `legal` on `[warned, distance, y, x, cost]`, so the
	# first `clean` entries of `tiles` are the clean ones. The paint reads that
	# invariant; this re-runs `evaluate()` over the painted set and pins it, so
	# the day the sort changes the ground does not quietly start lying.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	var model := SitePaintModel.new(root.config)
	var seen: Dictionary = {}
	for card: String in ["house", "store", "police_station", "pump", "source"]:
		if not bool(controller.enter(card)["ok"]):
			continue
		for centre in [Vector2i(40, 40), SHORE]:
			var hint := controller.placement_sites(centre)
			var paint := model.paint(hint, controller.ghost(),
					controller.centre_offset(), controller.tile_m)
			for raw: Variant in (paint["tiles"] as Array):
				var row: Dictionary = raw
				var verdict := String(controller.evaluate(row["origin"])["verdict"])
				var glyph := int(row["glyph"])
				seen[glyph] = int(seen.get(glyph, 0)) + 1
				if glyph == 0:
					assert_eq(verdict, String(BuildController.VERDICT_VALID),
							"a `normal` mark is a site the ghost calls VALID (%s at %s)"
							% [card, str(row["origin"])])
				else:
					assert_eq(glyph, 1,
							"the ground draws no mark the legend does not carry")
					assert_eq(verdict, String(BuildController.VERDICT_WARN),
							"a `warning` mark is doc 93 §BD9's warned site (%s at %s)"
							% [card, str(row["origin"])])
		controller.cancel()
	assert_true(seen.has(0), "at least one clean site was drawn")
	root.build_sheet.cancel_placement() if root.build_sheet != null else null
	_unmount(root)


func test_the_warned_tail_of_a_window_wears_the_warning_mark() -> void:
	# The clean/warned split, on a hand-built window — because whether the
	# founding city happens to offer a site on a full pole-top is the sim's
	# business and this is arithmetic. Five origins, two of them clean, is
	# exactly the shape `placement_sites` publishes: `tiles` sorted with the
	# warned ones last, `clean` counting the whole window.
	var model := SitePaintModel.new(UIConfig.load_from_files())
	var hint := {
		"centre": Vector2i(40, 40), "radius": 10, "count": 5, "clean": 2,
		"nearest": Vector2i(41, 40),
		"tiles": [Vector2i(41, 40), Vector2i(43, 40), Vector2i(38, 40),
				Vector2i(45, 45), Vector2i(31, 31)] as Array[Vector2i],
	}
	var ghost := {"visible": true, "origin": Vector2i(40, 40), "size": Vector2i(1, 1)}
	var paint := model.paint(hint, ghost, Vector2i.ZERO, 8.0)
	var rows: Array = paint["tiles"] as Array
	assert_eq(rows.size(), 5)
	for i in rows.size():
		var row: Dictionary = rows[i]
		var expect_clean := i < 2
		assert_eq(int(row["glyph"]), 0 if expect_clean else 1,
				"row %d wears the %s mark" % [i, "clean" if expect_clean else "warning"])
		assert_eq(String(row["state"]),
				String(HudModel.STATE_NORMAL if expect_clean else HudModel.STATE_WARNING))
	# `clean` is capped at what is DRAWN: a window with 200 clean sites and 32
	# rows must not claim 200 marks.
	hint["clean"] = 200
	var capped := model.paint(hint, ghost, Vector2i.ZERO, 8.0)
	assert_eq(int(capped["clean"]), 5, "clean never exceeds the drawn set")


func test_the_funds_sentence_names_the_price_the_tile_was_quoted() -> void:
	# **`A91-D-163`, found by driving the shell for this wave's preview shot.**
	# The founding city opens at $24,133 and a river intake is $38,086, so every
	# shoreline tile refuses for `E_FUNDS` alone — and Wave 28's funds sentence
	# read the price off `found["cost"]`, which is the cheapest LEGAL site's and
	# is therefore 0 in the one branch where nothing is legal. The bar told the
	# player, in words, *"a spot 3 tiles away would take this and it costs $0;
	# the treasury holds $24.1K"*. The quote that refused knows the number.
	var sim := _sim()
	var controller := BuildController.new(sim, RequirementFormatter.load_from_files())
	assert_true(bool(controller.enter_water_component("source")["ok"]))
	var quoted := int((controller.evaluate(Vector2i(35, 49))["params"]
			as Dictionary).get("cost", 0))
	assert_eq(quoted, 38086, "the intake at (35, 49) is quoted $38,086")
	assert_true(int(sim.treasury.balance) < quoted,
			"…and the founding city cannot afford it: $%d" % int(sim.treasury.balance))
	var advice: Dictionary = controller.placement_sites(SHORE)["advice"]
	assert_eq(String(advice["key"]), "ui_site_funds")
	assert_eq(int(advice["cost"]), quoted, "the sentence's price is the quote's")
	assert_eq(String((advice["args"] as Dictionary)["cost"]),
			RequirementFormatter.money(quoted),
			"…and it renders as $38.1K, not as $0")
	assert_ne(String((advice["args"] as Dictionary)["cost"]), "$0")
	controller.cancel()


func test_the_ground_borrows_the_legends_own_hue_and_follows_the_colourblind_palette() -> void:
	# A6: the hue is `data/ui.json.palette`'s, decoded to LINEAR at the write
	# (RR-91 — a MultiMesh instance colour takes no sRGB decode), and it moves
	# when the player switches the accessibility palette. `rebuild_theme()`
	# rebuilds a `Theme` and reaches no MultiMesh, which is why the sheet has a
	# `set_palette_variant` at all.
	var cfg := UIConfig.load_from_files()
	var default_model := SitePaintModel.new(cfg, "default")
	var palette := cfg.palette("default")
	for state: StringName in [HudModel.STATE_NORMAL, HudModel.STATE_WARNING]:
		var expected := Color(str(palette[String(state)])).srgb_to_linear()
		var got := default_model.hue(state)
		assert_almost_eq(got.r, expected.r, 0.0005, "%s red" % state)
		assert_almost_eq(got.g, expected.g, 0.0005, "%s green" % state)
		assert_almost_eq(got.b, expected.b, 0.0005, "%s blue" % state)
	# The glyph is the legend's own name, not a fifth mark invented here.
	assert_eq(default_model.glyph_char(HudModel.STATE_NORMAL),
			str(HudModel.STATE_GLYPH_CHARS[str(cfg.section("state_glyphs")["normal"])]))
	assert_eq(default_model.glyph_index(HudModel.STATE_NORMAL), 0)
	assert_eq(default_model.glyph_index(HudModel.STATE_WARNING), 1)
	# And a variant that recolours `normal` recolours the ground.
	var variants: Dictionary = cfg.section("palette")
	var moved := false
	for name: String in variants:
		if name == "default":
			continue
		var over: Dictionary = variants[name]
		if not over.has(String(HudModel.STATE_NORMAL)):
			continue
		var model := SitePaintModel.new(cfg, name)
		assert_ne(model.hue(HudModel.STATE_NORMAL),
				default_model.hue(HudModel.STATE_NORMAL),
				"the `%s` palette moves the ground with the legend" % name)
		moved = true
	assert_true(moved, "at least one colourblind variant recolours `normal`")


func test_the_sheet_hands_the_palette_switch_through_to_the_ground() -> void:
	var root := _mount()
	var sim := _sim()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	var variants: Dictionary = root.config.section("palette")
	var target := ""
	for name: String in variants:
		if name != "default" and (variants[name] as Dictionary).has("normal"):
			target = name
			break
	if target == "":
		_unmount(root)
		return
	sim.treasury.balance = 5_000_000
	assert_true(bool(controller.enter("house")["ok"]))
	_stand(root.build_sheet, controller, Vector2i(40, 40))
	var before: Dictionary = (root.build_sheet.site_paint()["tiles"] as Array)[0]
	root.build_sheet.set_palette_variant(target)
	var after: Dictionary = (root.build_sheet.site_paint()["tiles"] as Array)[0]
	assert_ne(before["hue"], after["hue"],
			"Settings ▸ colourblind reaches the ground, not just the Theme")
	root.build_sheet.cancel_placement()
	_unmount(root)


# ===========================================================================
# 4. THE FADE, AND THE ONE THE SENTENCE NAMES
# ===========================================================================

func test_the_paint_fades_from_the_ghost_and_rings_the_site_the_sentence_names() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter("house")["ok"]))
	_stand(root.build_sheet, controller, Vector2i(40, 40))
	var model := SitePaintModel.new(root.config)
	var paint := root.build_sheet.site_paint()
	var rows: Array = paint["tiles"] as Array
	assert_true(rows.size() > 4, "the founding city offers plenty of house plots")
	var near := model.alpha_near()
	var far := model.alpha_far()
	assert_true(near > far, "near is the loud end")
	var rings := 0
	for raw: Variant in rows:
		var row: Dictionary = raw
		var a := float(row["alpha"])
		assert_true(a <= near + 0.0001 and a >= far - 0.0001,
				"%.3f is inside the authored band" % a)
		# The fade IS the distance, monotonically.
		var t := clampf(float(int(row["distance"])) / float(int(paint["radius"])),
				0.0, 1.0)
		assert_almost_eq(a, lerpf(near, far, t), 0.0005,
				"alpha at %d tiles" % int(row["distance"]))
		if bool(row["nearest"]):
			rings += 1
			assert_eq(row["origin"], paint["nearest"],
					"the ring is on the site the bar's sentence names")
	assert_eq(rings, 1, "exactly one ring: the sentence names one site")
	root.build_sheet.cancel_placement()
	_unmount(root)


# ===========================================================================
# 5. THE BUDGET — one call lit, none at rest, and never a re-scan per frame
# ===========================================================================

func test_the_layer_costs_one_draw_call_lit_and_none_at_rest() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	var view := SitePaintView.new()
	_tree().root.add_child(view)
	view.setup(SitePaintModel.new(root.config), controller.tile_m)
	assert_eq(view.draw_calls(), 0, "a game with nothing being placed pays nothing")
	assert_true(bool(controller.enter("house")["ok"]))
	var bad := _first_blocked_near(controller, Vector2i(40, 40))
	_stand(root.build_sheet, controller, bad)
	var lit := view.apply(root.build_sheet.site_paint())
	assert_true(lit > 0, "the window found sites and the ground shows them")
	assert_eq(view.draw_calls(), 1, "one MultiMesh, one material, one call")
	assert_eq(view.tile_count(), lit)
	assert_eq(view.buffer_mirror().size(), lit * SitePaintView.STRIDE)
	root.build_sheet.cancel_placement()
	view.apply(root.build_sheet.site_paint())
	assert_eq(view.draw_calls(), 0, "placement over, the node goes dark again")
	_tree().root.remove_child(view)
	view.free()
	_unmount(root)


func test_the_buffer_is_not_rewritten_while_the_picture_has_not_changed() -> void:
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	var view := SitePaintView.new()
	_tree().root.add_child(view)
	view.setup(SitePaintModel.new(root.config), controller.tile_m)
	assert_true(bool(controller.enter("house")["ok"]))
	var bad := _first_blocked_near(controller, Vector2i(40, 40))
	_stand(root.build_sheet, controller, bad)
	var paint := root.build_sheet.site_paint()
	view.apply(paint)
	var after_first := view.uploads
	# §2.7 revalidates at 10 Hz and the shell re-applies with it. A ghost that
	# has not moved must cost NOTHING — this is the whole "no per-frame
	# recompute" clause, measured rather than asserted in prose.
	for _i in 30:
		view.apply(root.build_sheet.site_paint())
	assert_eq(view.uploads, after_first,
			"30 more applies, zero uploads")
	assert_eq(view.applies, 31)
	_tree().root.remove_child(view)
	view.free()
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_the_window_is_scanned_once_per_window_and_not_once_per_move() -> void:
	# Doc 93 §BD8's memo, from the paint's side: the ghost may walk anywhere
	# inside the window that was scanned and the window does not move. It moves
	# when the ghost leaves it, and that is the only time 441 previews are paid
	# for again.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter("house")["ok"]))
	_stand(root.build_sheet, controller, Vector2i(40, 40))
	var centre: Vector2i = root.build_sheet.site_hint()["centre"]
	var reach := int(root.build_sheet.site_hint()["radius"])
	for step in [1, 2, 3, 5, 8]:
		_stand(root.build_sheet, controller, Vector2i(40 + step, 40 + step))
		assert_eq(root.build_sheet.site_paint()["centre"], centre,
				"a move of %d tiles inside the window does not re-scan" % step)
	_stand(root.build_sheet, controller, Vector2i(40 + reach + 2, 40))
	assert_ne(root.build_sheet.site_paint()["centre"], centre,
			"…and walking out of it does")
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_a_batch_that_changed_the_ground_throws_the_memo_away() -> void:
	# The other half of the memo's guard (D-130 requirement 3). §BD8 is right
	# that the answer does not change while the finger moves; it says nothing
	# about the settlement that just lifted austerity, which on
	# `player_save_0903` is the ONLY thing refusing all three shoreline sites.
	var sim := _sim()
	sim.treasury.balance = 5_000_000
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter("house")["ok"]))
	_stand(root.build_sheet, controller, Vector2i(40, 40))
	assert_false(root.build_sheet.site_hint().is_empty(), "a window is memoised")
	# An event that changes nothing about the ground leaves the memo alone.
	root.feed_events([{"type": &"weather_changed"}])
	assert_false(root.build_sheet.site_hint().is_empty())
	# One that does throws it away.
	root.feed_events([{"type": &"block_purchased", "payload": {}}])
	assert_true(root.build_sheet._site_hint.is_empty(),
			"the ground the player just bought is a window worth re-scanning")
	# …and the very next read rebuilds it, so nothing is left dark.
	assert_false(root.build_sheet.site_hint().is_empty())
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_every_event_that_may_throw_the_window_away_is_one_the_sim_emits() -> void:
	# A census, not a list. An invalidation keyed on a name nothing publishes is
	# a guard that never fires and looks exactly like a guard that works —
	# `A91-D-19`'s shape, in the fix for `A91-D-19`'s shape.
	var text := ""
	for path in _gd_files("res://sim"):
		text += FileAccess.get_file_as_string(path)
	for name: StringName in BuildSheet.SITE_GROUND_EVENTS:
		assert_true(text.contains('&"%s"' % String(name)),
				"`%s` is an event `sim/` actually emits" % String(name))


# ===========================================================================
# 6. THE PLAYER'S OWN SAVE — the city the whole read was built for
# ===========================================================================

func test_the_players_own_save_has_no_lit_tile_by_his_plant() -> void:
	# The state the sentence exists for, and the state the PAINT has to be
	# honest about: there is nothing to light, and drawing an empty set is not
	# the same as drawing nothing. The bar carries the answer in words and the
	# door under it carries the camera.
	var sim := _restore_player_save()
	if sim == null:
		assert_true(false, "tests/fixtures/player_save_0903 did not restore")
		return
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	root.build_sheet.setup(root.config, controller)
	assert_true(bool(controller.enter_water_component("source")["ok"]))
	var hint := controller.placement_sites()
	assert_eq(int(hint["count"]), 0,
			"no legal tile within %d of his plant — the sentence Wave 28 was built for"
			% int(hint["radius"]))
	var model := SitePaintModel.new(root.config)
	var paint := model.paint(hint, controller.ghost(), controller.centre_offset(),
			controller.tile_m)
	assert_false(bool(paint["visible"]), "nothing to light")
	assert_eq((paint["tiles"] as Array).size(), 0)
	assert_eq(int(paint["radius"]), int(hint["radius"]),
			"…and the empty paint still says which window was asked")
	var view := SitePaintView.new()
	_tree().root.add_child(view)
	view.setup(model, controller.tile_m)
	assert_eq(view.apply(paint), 0)
	assert_eq(view.draw_calls(), 0, "an empty answer costs no draw call")
	_tree().root.remove_child(view)
	view.free()
	root.build_sheet.cancel_placement()
	_unmount(root)


func test_the_players_own_save_lights_three_intakes_once_the_freeze_lifts() -> void:
	# The other end of the same drive. His three shoreline sites refuse for
	# `E_AUSTERITY` and NOTHING ELSE (doc 12 D-127's own note: the freeze lifts
	# at the first hourly settlement after the load, at a balance of
	# $14,899,376). This asserts both halves — that the window is empty while
	# the freeze is on, and that the same window lights three the moment it is
	# off, which is what makes `austerity_exited` an invalidation event.
	var sim := _restore_player_save()
	if sim == null:
		assert_true(false, "tests/fixtures/player_save_0903 did not restore")
		return
	assert_true(sim.treasury.austerity_active,
			"the fixture restores the freeze verbatim")
	var root := _mount()
	var controller := BuildController.new(sim, RequirementFormatter.new(root.config))
	var model := SitePaintModel.new(root.config)
	var frozen := controller_sites(controller, SHORE)
	assert_eq(int(frozen["count"]), 0, "frozen: nothing on the shore is buildable")
	assert_eq(int((frozen["reasons"] as Dictionary).get(&"E_AUSTERITY", 0)), 3,
			"…and exactly three tiles refuse for the freeze alone")
	sim.treasury.austerity_active = false
	var lifted := controller_sites(controller, SHORE)
	assert_eq(int(lifted["count"]), 3, "lifted: three intakes, 41 tiles from his plant")
	assert_eq(int(lifted["clean"]), 3, "all three will run")
	assert_eq(lifted["nearest"], Vector2i(35, 49))
	assert_eq(int(lifted["cost"]), 38086)
	var paint := model.paint(lifted, controller.ghost(), controller.centre_offset(),
			controller.tile_m)
	assert_true(bool(paint["visible"]))
	assert_eq((paint["tiles"] as Array).size(), 3)
	for raw: Variant in (paint["tiles"] as Array):
		assert_eq(int((raw as Dictionary)["glyph"]), 0,
				"three clean intakes wear the clean mark")
	root.build_sheet.cancel_placement()
	_unmount(root)


func controller_sites(controller: BuildController, centre: Vector2i) -> Dictionary:
	if not controller.is_placing():
		assert_true(bool(controller.enter_water_component("source")["ok"]))
	return controller.placement_sites(centre)


# ---------------------------------------------------------------- fixtures

func _first_legal(controller: BuildController) -> Vector2i:
	var found := controller.placement_sites(Vector2i(40, 40))
	var tiles: Array = found["tiles"] as Array
	return tiles[0] if not tiles.is_empty() else Vector2i(-1, -1)


## A tile the ghost refuses, as near the middle of the founding city as one is —
## the state a blocked player is actually in.
func _first_blocked_near(controller: BuildController, home: Vector2i) -> Vector2i:
	for r in range(1, 12):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := Vector2i(home.x + dx, home.y + dy)
				if not TileGrid.in_bounds(tile.x, tile.y):
					continue
				if String(controller.evaluate(tile)["verdict"]) \
						== String(BuildController.VERDICT_BLOCKED):
					return tile
	return Vector2i(-1, -1)


static func _gd_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## The fixture, copied into this process's own `user://` and loaded through the
## real `SaveService` — never read in place, because a load can promote a legacy
## file and roll a generation, and a test must not edit the fixture it reads.
func _restore_player_save() -> CitySim:
	var dest := "user://test_saves/site_paint_fixture"
	DirAccess.make_dir_recursive_absolute(dest)
	if _copy_tree("res://tests/fixtures/player_save_0903", dest) == 0:
		return null
	var sim := CitySim.boot_from_files(1337)
	var service := SaveService.new()
	service.base_dir = dest
	_tree().root.add_child(service)
	var ok := service.load_slot(sim, 0)
	_tree().root.remove_child(service)
	service.free()
	return sim if ok else null


static func _copy_tree(source: String, dest: String) -> int:
	var dir := DirAccess.open(source)
	if dir == null:
		return 0
	var copied := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var from := source.path_join(entry)
		var to := dest.path_join(entry)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(to)
			copied += _copy_tree(from, to)
		else:
			if DirAccess.copy_absolute(from, to) == OK:
				copied += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return copied
