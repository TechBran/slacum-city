extends SimTest
## S0 — the front door (doc 12 §2.2's one screen with no node until now).
##
## Three things are worth testing here and the third is the reason the file
## exists:
##
##   1. **CONTINUE says which city it resumes.** Day, population and treasury off
##      `SaveService`'s own meta header, formatted the way the slot list formats
##      them, so the same save reads the same on both screens.
##   2. **The door is absent unless asked for.** Every headless mount on the deck
##      — `tests/test_tutorial_flow.gd`, `tests/test_ui_audit.gd`,
##      `tools/ui_preview.gd` — instantiates the same scene, and a front door
##      that came up by itself would put a modal in front of all of them. Only
##      `UIRoot.present_title()` opens it.
##   3. **NEW CITY cannot silently orphan the old one.** `SaveService`'s autosave
##      rotation belongs to whatever city is LIVE, so a new city takes it over
##      and two autosaves later both halves hold the new city. That is not a bug
##      to fix in `ui/` — it is a fact to surface, which is what
##      `TitleModel.new_game_plan()` does: it names the manual saves that survive,
##      says the autosave is what a new city costs, and offers the outgoing city
##      the lowest free manual slot before it goes. When there is no free slot it
##      says THAT, rather than picking one of the player's own saves to sacrifice.
##
## The stubs below are `game/save_service.gd`'s READ side and nothing else —
## `list_slots`, `latest_slot`, `autosave_slots`. `TitleModel` never writes, so
## there is nothing else for it to call.

const BOXES: Array[Vector2i] = [
	Vector2i(360, 800), Vector2i(412, 915), Vector2i(794, 924), Vector2i(880, 400),
	Vector2i(1280, 720),
]
const TITLE_PANEL := "TitleLayer/TitleScreen/Center/Panel"
## `data/ui.json.save_slots.count` is 3 and `SaveService` hides its autosave
## shadow at 7, so the manual slots a player can see are 1 and 2.
const ROTATION: Array[int] = [0, 7]


class SlotStub extends RefCounted:
	var slots: Dictionary = {}       # slot -> meta
	var rotation: Array[int] = ROTATION

	func _init(occupied: Dictionary = {}) -> void:
		for slot: Variant in occupied:
			var at: int = int((occupied[slot] as Dictionary).get("saved_at_unix", 0))
			slots[int(slot)] = {"slot": int(slot), "saved_at_unix": at,
					"day_index": int((occupied[slot] as Dictionary).get("day_index", 0)),
					"population": int((occupied[slot] as Dictionary).get("population", 0)),
					"treasury": int((occupied[slot] as Dictionary).get("treasury", 0))}

	func list_slots() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var keys: Array = slots.keys()
		keys.sort()
		for key: Variant in keys:
			out.append((slots[key] as Dictionary).duplicate())
		return out

	func latest_slot() -> int:
		var best := -1
		var best_at := -1
		for slot: Variant in slots:
			var at := int((slots[slot] as Dictionary)["saved_at_unix"])
			if at > best_at:
				best_at = at
				best = int(slot)
		return best

	func autosave_slots() -> Array[int]:
		return rotation


## The service that publishes no rotation — `TitleModel` must degrade to "one
## autosave slot" rather than guessing at a shadow it was never told about.
class NoRotationStub extends SlotStub:
	func autosave_slots() -> Array[int]:
		return []


static func _meta(day: int, population: int, treasury: int, at: int) -> Dictionary:
	return {"saved_at_unix": at, "day_index": day, "population": population,
			"treasury": treasury}


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _model(stub: Object = null) -> TitleModel:
	var model := TitleModel.new(_cfg())
	if stub != null:
		model.bind(stub)
	return model


# ===========================================================================
# CONTINUE
# ===========================================================================

func test_continue_is_refused_until_there_is_something_to_continue() -> void:
	var bare := _model()
	assert_false(bare.is_available(), "no service bound yet")
	assert_false(bool(bare.continue_row()["enabled"]))
	assert_eq(int(bare.continue_row()["slot"]), -1)
	assert_eq(str(bare.continue_row()["summary"]),
			_cfg().t("ui_title_continue_empty"), "the door says so in words (A14)")

	var empty := _model(SlotStub.new())
	assert_true(empty.is_available())
	assert_false(bool(empty.continue_row()["enabled"]), "a bound service with no saves")
	assert_false(empty.has_any_save())


func test_continue_names_the_city_it_would_resume() -> void:
	var model := _model(SlotStub.new({
		0: _meta(12, 184291, 8420000, 1755500000),
		1: _meta(3, 1204, 42000, 1755000000),
	}))
	var row := model.continue_row()
	assert_true(bool(row["enabled"]))
	assert_eq(int(row["slot"]), 0, "the newest save, not the lowest slot")
	# Doc 12 §2.2 wants day N, population and treasury, and `SaveSlotsModel`
	# already owns that sentence — the front door must not invent a second one.
	var summary := str(row["summary"])
	assert_true(summary.contains("13"), "day_index 12 is day 13: %s" % summary)
	assert_true(summary.contains(HudModel.pop(184291)), summary)
	assert_true(summary.contains(HudModel.money(8420000)), summary)
	assert_ne(str(row["saved_text"]), "", "and when it was saved")
	assert_false(summary.contains("{"), "no placeholder left unresolved")


func test_the_primary_button_is_whichever_answer_the_player_has() -> void:
	var fresh := _model(SlotStub.new()).actions()
	assert_eq(fresh.size(), 3)
	for row: Dictionary in fresh:
		if StringName(row["action"]) == TitleModel.ACTION_NEW_GAME:
			assert_true(bool(row["primary"]), "a first launch leads with NEW CITY")
		if StringName(row["action"]) == TitleModel.ACTION_CONTINUE:
			assert_false(bool(row["enabled"]))
	var returning := _model(SlotStub.new({0: _meta(4, 900, 12000, 1755500000)})).actions()
	for row: Dictionary in returning:
		if StringName(row["action"]) == TitleModel.ACTION_CONTINUE:
			assert_true(bool(row["primary"]), "a returning player leads with CONTINUE")
			assert_true(bool(row["enabled"]))
		if StringName(row["action"]) == TitleModel.ACTION_SETTINGS:
			assert_false(bool(row["primary"]), "SETTINGS is never the primary")


# ===========================================================================
# NEW CITY — the slot ruling
# ===========================================================================

func test_a_first_launch_asks_nothing() -> void:
	var plan := _model(SlotStub.new()).new_game_plan()
	assert_false(bool(plan["needs_confirm"]), "nothing exists, nothing is lost")
	assert_false(bool(plan["replaced"]))
	assert_eq(int(plan["archive_from"]), -1)


func test_a_city_that_lives_only_in_the_autosave_is_offered_a_home() -> void:
	# The common case, and the one this whole ruling exists for: the player has
	# never touched the save screen, so their city is in the rotation — which the
	# next city's first autosave overwrites.
	var model := _model(SlotStub.new({0: _meta(12, 184291, 8420000, 1755500000)}))
	var plan := model.new_game_plan()
	assert_true(bool(plan["needs_confirm"]))
	assert_true(bool(plan["replaced"]), "the autosave is what a new city costs")
	assert_eq(int(plan["archive_from"]), 0, "the city to rescue")
	assert_eq(int(plan["archive_to"]), 1, "the lowest free manual slot")
	assert_true(bool(plan["can_keep"]))
	assert_false(bool(plan["blocked_keep"]))
	assert_eq(str(plan["kept"]), "[]", "there is no manual save to name yet")
	assert_true(str(plan["prompt"]).contains(_cfg().t("ui_saves_slot_autosave")),
			"the prompt says the autosave goes: %s" % str(plan["prompt"]))
	assert_false(str(plan["prompt"]).contains("{"))
	# The answer the shell acts on.
	var kept := model.confirm_new_game(true)
	assert_eq(int(kept["archive_from"]), 0)
	assert_eq(int(kept["archive_to"]), 1)
	assert_eq(int(kept["slot"]), 1, "title_new_game carries where it went")
	var dropped := model.confirm_new_game(false)
	assert_eq(int(dropped["slot"]), -1, "START NEW keeps nothing, and says so")


func test_the_plan_names_the_saves_it_will_not_delete() -> void:
	var model := _model(SlotStub.new({
		0: _meta(12, 184291, 8420000, 1755500000),
		1: _meta(3, 1204, 42000, 1755000000),
	}))
	var plan := model.new_game_plan()
	assert_eq(str(plan["kept"]), "[1]", "the manual slot survives untouched")
	assert_eq(int(plan["archive_to"]), 2, "and the rescue takes the next free one")
	var prompt := str(plan["prompt"])
	assert_true(prompt.contains(model.slot_title(1)),
			"doc 12: name the save it will NOT delete — %s" % prompt)


func test_a_full_profile_refuses_to_pick_a_victim() -> void:
	var model := _model(SlotStub.new({
		0: _meta(12, 184291, 8420000, 1755500000),
		1: _meta(3, 1204, 42000, 1755000000),
		2: _meta(9, 5400, 91000, 1755100000),
	}))
	var plan := model.new_game_plan()
	assert_eq(int(plan["archive_from"]), 0)
	assert_eq(int(plan["archive_to"]), -1, "no free manual slot")
	assert_true(bool(plan["blocked_keep"]))
	assert_false(bool(plan["can_keep"]))
	assert_eq(str(plan["keep_note"]), _cfg().t("ui_title_confirm_no_room"),
			"it points at Settings ▸ Manage saves instead of overwriting Slot 1")
	assert_eq(str(plan["kept"]), "[1, 2]")
	# And KEEP cannot be forced through a stale view.
	assert_eq(int(model.confirm_new_game(true)["slot"]), -1)


func test_a_city_already_in_a_manual_slot_needs_no_rescue() -> void:
	var model := _model(SlotStub.new({1: _meta(6, 2100, 66000, 1755500000)}))
	var plan := model.new_game_plan()
	assert_true(bool(plan["needs_confirm"]), "a big action still asks")
	assert_eq(int(plan["archive_from"]), -1, "the newest save is already durable")
	assert_false(bool(plan["replaced"]), "and the rotation holds nothing to lose")
	assert_eq(str(plan["kept"]), "[1]")


func test_the_shadow_half_is_asked_for_rather_than_assumed() -> void:
	# An autosave slot sits OUTSIDE every slot the player can see, so
	# `data/ui.json` cannot name it and the model has to ask the service. The
	# stub still publishes two, because the CONTRACT is "whatever the service
	# lists", not "one" — doc 08 §2.7 retired the real second slot in Wave 7 and
	# the shipped `SaveService.autosave_slots()` now answers `[0]`, but a model
	# that hard-codes that is a model that breaks the next time the answer moves.
	var model := _model(SlotStub.new())
	assert_eq(str(model.rotation_slots()), str(ROTATION))
	assert_eq(str(model.manual_slots()), "[1, 2]", "3 visible slots, 0 is the autosave")
	# A service that publishes no pair degrades to one slot — conservative, since
	# it can only ever over-report what survives.
	var lonely := _model(NoRotationStub.new())
	assert_eq(str(lonely.rotation_slots()), "[0]")
	assert_eq(str(lonely.manual_slots()), "[1, 2]")


func test_both_halves_of_the_rotation_read_as_one_autosave() -> void:
	# Slot 7 is not "Slot 7" to a player: it is the other half of the autosave,
	# and naming it as a numbered slot would invent a slot the save screen does
	# not show.
	var model := _model(SlotStub.new({7: _meta(5, 800, 30000, 1755500000)}))
	assert_eq(model.slot_title(7), _cfg().t("ui_saves_slot_autosave"))
	var plan := model.new_game_plan()
	assert_true(bool(plan["replaced"]))
	assert_eq(int(plan["archive_from"]), 7, "the live city is in the shadow half")
	assert_eq(int(plan["archive_to"]), 1)


# ===========================================================================
# The screen, mounted
# ===========================================================================

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _mount(text_scale: float = 1.0, larger: bool = false) -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	root.config = UIConfig.load_from_files()
	var defaults: Dictionary = root.config.ui_data()["defaults"]
	defaults["text_scale"] = text_scale
	defaults["larger_touch_targets"] = larger
	_tree().root.add_child(root)
	root.initialize()
	return root


func _unmount(root: UIRoot) -> void:
	_tree().root.remove_child(root)
	root.free()


func test_the_scene_carries_a_front_door_and_never_opens_it() -> void:
	var root := _mount()
	assert_ne(root.title_layer, null, "SafeArea/TitleLayer")
	assert_ne(root.title_screen, null, "SafeArea/TitleLayer/TitleScreen")
	assert_eq(root.title_layer.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"the layer never eats a touch")
	# THE contract: a plain mount — which is every headless mount on the deck —
	# gets no title. `tests/test_tutorial_flow.gd` drives the whole tutorial
	# through this same scene and must never meet one.
	assert_false(root.title_open(), "closed until someone asks")
	assert_eq(root.title_screen.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_true(root.present_title())
	assert_true(root.title_open())
	assert_eq(root.title_screen.mouse_filter, Control.MOUSE_FILTER_STOP,
			"and it swallows every touch once it is up — there is no city behind it")
	root.dismiss_title()
	assert_false(root.title_open())
	_unmount(root)


## The front door sits above the city deck and below the modals: it covers the
## HUD, the panels and the sheets, and SETTINGS opened from it covers the door.
func test_the_title_layer_sits_above_the_deck_and_below_the_modals() -> void:
	var root := _mount()
	var order: PackedStringArray = []
	for child in root.safe_area.get_children():
		order.append(str(child.name))
	var title := Array(order).find("TitleLayer")
	assert_true(title > Array(order).find("SheetLayer"), str(order))
	assert_true(title < Array(order).find("ModalLayer"), str(order))
	_unmount(root)


func test_continue_is_an_intent_and_the_shell_closes_the_door() -> void:
	var root := _mount()
	root.title_screen.bind_service(SlotStub.new({0: _meta(12, 184291, 8420000, 1755500000)}))
	root.present_title()
	var seen: Array[int] = []
	root.title_continue.connect(func(slot: int) -> void: seen.append(slot))
	root.title_screen.action_button(TitleModel.ACTION_CONTINUE).pressed.emit()
	assert_eq(str(seen), "[0]", "the slot the shell should restore")
	# A restore that fails must leave the player looking at the door, so the view
	# closes nothing by itself.
	assert_true(root.title_open(), "still up until the shell says otherwise")
	_unmount(root)


func test_new_city_confirms_and_carries_the_slot_it_preserved() -> void:
	var root := _mount()
	root.title_screen.bind_service(SlotStub.new({0: _meta(12, 184291, 8420000, 1755500000)}))
	root.present_title()
	var seen: Array[int] = []
	root.title_new_game.connect(func(slot: int) -> void: seen.append(slot))

	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	assert_true(root.title_screen.confirm_visible(), "a save exists, so it asks")
	assert_eq(str(seen), "[]", "and nothing has happened yet")
	assert_true(root.title_screen.confirm_button(&"keep").visible)

	root.title_screen.confirm_button(&"cancel").pressed.emit()
	assert_false(root.title_screen.confirm_visible())
	assert_eq(str(seen), "[]")

	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	root.title_screen.confirm_button(&"keep").pressed.emit()
	assert_eq(str(seen), "[1]", "the outgoing city was preserved into Slot 1")
	assert_false(root.title_screen.confirm_visible())

	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	root.title_screen.confirm_button(&"start").pressed.emit()
	assert_eq(str(seen), "[1, -1]", "START NEW preserves nothing")
	_unmount(root)


func test_a_first_launch_starts_without_a_question() -> void:
	var root := _mount()
	root.title_screen.bind_service(SlotStub.new())
	root.present_title()
	var seen: Array[int] = []
	root.title_new_game.connect(func(slot: int) -> void: seen.append(slot))
	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	assert_false(root.title_screen.confirm_visible(), "nothing to lose, nothing to ask")
	assert_eq(str(seen), "[-1]")
	_unmount(root)


func test_a_full_profile_offers_start_but_not_keep() -> void:
	var root := _mount()
	root.title_screen.bind_service(SlotStub.new({
		0: _meta(12, 184291, 8420000, 1755500000),
		1: _meta(3, 1204, 42000, 1755000000),
		2: _meta(9, 5400, 91000, 1755100000),
	}))
	root.present_title()
	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	assert_true(root.title_screen.confirm_visible())
	assert_false(root.title_screen.confirm_button(&"keep").visible,
			"there is nowhere to keep it, so the button is not offered")
	assert_true(root.title_screen.confirm_button(&"start").visible)
	_unmount(root)


func test_settings_opens_over_the_door_and_leaves_it_up() -> void:
	var root := _mount()
	root.present_title()
	# An Array and not an int: a GDScript lambda captures a local by VALUE, so a
	# counter incremented inside one never reaches the assertion.
	var seen: Array[int] = []
	root.title_settings.connect(func() -> void: seen.append(1))
	root.title_screen.action_button(TitleModel.ACTION_SETTINGS).pressed.emit()
	assert_eq(seen.size(), 1)
	assert_true(root.settings_sheet.is_open(), "the root serves the route it owns")
	assert_true(root.title_open(), "S9 opens OVER the title, it does not replace it")
	_unmount(root)


func test_starting_a_new_city_forgets_the_tutorial() -> void:
	# §2.17's "never shows again once done" is per CITY, not per install: a new
	# city has never been through it, whatever the previous one did.
	var root := _mount()
	root.title_screen.bind_service(SlotStub.new())
	root.start_onboarding({"tutorial_lot_a": Vector2i(43, 40)})
	assert_true(root.onboarding_active())
	root.onboarding.skip()
	assert_false(root.onboarding_active())
	assert_false(root.start_onboarding({"tutorial_lot_a": Vector2i(43, 40)}),
			"§2.17: a finished tutorial never shows again on the same city")
	root.present_title()
	root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()
	assert_true(root.start_onboarding({"tutorial_lot_a": Vector2i(43, 40)}),
			"the reset behind NEW CITY makes the tutorial startable again")
	_unmount(root)


# ===========================================================================
# Back (doc 12 §2.2)
# ===========================================================================

func test_the_front_door_has_no_city_rungs_behind_it() -> void:
	# Nothing on the city deck can be open while the door is up, so back means
	# "leave the app" — the same two-press pair an idle city takes.
	var ctx := {"title_open": true, "sheet_open": true, "panel_open": true,
			"placement_active": true, "has_selection": true,
			"back_pressed_recently": false}
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_PROMPT_MINIMISE)
	ctx["back_pressed_recently"] = true
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_MINIMISE)
	# But SETTINGS opened FROM the door is a modal, and a modal always closes
	# first — otherwise back at the settings sheet would quit the game.
	ctx["modal_open"] = true
	assert_eq(UIRoot.resolve_back(ctx), UIRoot.BACK_CLOSE_MODAL)


func test_back_at_the_title_reaches_the_resolver_through_the_live_context() -> void:
	var root := _mount()
	root.present_title()
	assert_true(bool(root.back_context(0.0)["title_open"]))
	assert_eq(root.handle_back(0.0), UIRoot.BACK_PROMPT_MINIMISE)
	assert_true(root.title_open(), "back does not dismiss the door")
	assert_eq(root.handle_back(500.0), UIRoot.BACK_MINIMISE, "second press within 2 s")
	_unmount(root)


# ===========================================================================
# The mark
# ===========================================================================

## `data/ui.json.title.skyline` IS `tools/gen_icon.py`'s `TOWERS` table, so the
## launcher icon, the boot splash and the front door are one drawing. This is the
## test that stops them drifting apart in silence.
func test_the_skyline_is_the_icons_own_geometry() -> void:
	var skyline := _cfg().section("title").get("skyline", {}) as Dictionary
	var towers: Array = skyline["towers"]
	assert_eq(towers.size(), 15, "gen_icon.py's TOWERS")
	assert_eq(int(skyline["hero"]), 6, "the hero tower carries the lit window")
	assert_almost_eq(float(skyline["width"]), 4.20, 1e-9, "SKYLINE_WIDTH")
	assert_almost_eq(float(skyline["ground_y"]), 1.0, 1e-9, "GROUND_Y")
	assert_eq(int(skyline["lit_col"]), 2)
	assert_eq(int(skyline["lit_row"]), 2)
	assert_eq(int(skyline["sieve_mod"]), 11, "one window in eleven is dark, no RNG")
	var hero: Array = towers[6]
	assert_almost_eq(float(hero[0]), 1.54, 1e-9)
	assert_almost_eq(float(hero[1]), 0.40, 1e-9)
	assert_almost_eq(float(hero[2]), 0.20, 1e-9)
	assert_eq(int(hero[3]), TitleScreen.CROWN_SPIRE, "the hero is the spire")
	# Every tower is on the map, in order, and none of them is inside out.
	var previous := -1.0
	for raw: Variant in towers:
		var row: Array = raw
		assert_eq(row.size(), 4, str(row))
		assert_true(float(row[0]) > previous, "towers are authored left to right")
		previous = float(row[0])
		assert_true(float(row[1]) > 0.0, "positive width")
		assert_true(float(row[2]) > 0.0 and float(row[2]) < float(skyline["ground_y"]),
				"a roof is above the street and below the sky's top")
		assert_true(int(row[3]) >= TitleScreen.CROWN_NONE
				and int(row[3]) <= TitleScreen.CROWN_SPIRE, "known crown")


func test_the_brand_ramp_is_every_colour_the_drawing_needs() -> void:
	var palette := _cfg().section("title").get("palette", {}) as Dictionary
	for token: String in ["sky_top", "sky_horizon", "ground", "silhouette",
			"window_dark", "amber", "amber_core"]:
		assert_true(palette.has(token), "title.palette carries %s" % token)
		assert_true(Color.html_is_valid(str(palette[token])),
				"%s is a colour: %s" % [token, str(palette[token])])
	assert_eq(str(palette["amber"]), "#FFB02A", "gen_icon.py's AMBER")


# ===========================================================================
# The audit, across every supported display
# ===========================================================================

func _open_title(root: UIRoot, confirming: bool) -> void:
	root.title_screen.bind_service(SlotStub.new({
		0: _meta(12, 184291, 8420000, 1755500000),
		1: _meta(3, 1204, 42000, 1755000000),
		2: _meta(9, 5400, 91000, 1755100000),
	}))
	root.present_title()
	if confirming:
		# The full-profile confirmation is the widest state the door has: it
		# carries the "no free slot" sentence AND three stacked verbs.
		root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()


func test_the_front_door_fits_every_supported_display() -> void:
	for confirming: bool in [false, true]:
		for box: Vector2i in BOXES:
			var root := _mount()
			_open_title(root, confirming)
			root.force_layout(box)
			var panel := root.safe_area.get_node_or_null(TITLE_PANEL) as Control
			assert_ne(panel, null, TITLE_PANEL)
			var wanted := panel.get_combined_minimum_size().x
			assert_true(wanted <= float(box.x),
					"the title needs %d dp on a %d dp display (confirm=%s)"
							% [int(wanted), box.x, confirming])
			_unmount(root)


func test_the_front_door_fits_the_narrowest_display_at_130_percent_text() -> void:
	for confirming: bool in [false, true]:
		var root := _mount(1.3, true)
		_open_title(root, confirming)
		root.force_layout(Vector2i(360, 800))
		var panel := root.safe_area.get_node_or_null(TITLE_PANEL) as Control
		var wanted := panel.get_combined_minimum_size().x
		assert_true(wanted <= 360.0,
				"the title needs %d dp at 130 %% text on a 360 dp display (confirm=%s)"
						% [int(wanted), confirming])
		_unmount(root)


func test_the_front_door_resolves_every_word_it_shows() -> void:
	for confirming: bool in [false, true]:
		var root := _mount()
		_open_title(root, confirming)
		var findings := UIAudit.walk_frame_free(root.title_layer)
		assert_eq(UIAudit.format(findings, ""), "  clean",
				"S0 copy, confirm=%s" % confirming)
		_unmount(root)


func test_every_door_names_itself_and_clears_the_touch_floor() -> void:
	for scale: float in [1.0, 1.3]:
		for confirming: bool in [false, true]:
			var root := _mount(scale, scale > 1.0)
			_open_title(root, confirming)
			root.force_layout(Vector2i(360, 800))
			var findings := UIAudit.only(UIAudit.walk(root.title_layer, 0.0, Rect2()),
					[UIAudit.KIND_NO_TOOLTIP, UIAudit.KIND_UNBOUNDED_CLIP])
			assert_eq(UIAudit.format(findings, ""), "  clean",
					"S0 at %d %% text, confirm=%s" % [int(scale * 100.0), confirming])
			var touch := float(ThemeBuilder.touch_min_dp(root.config, scale, scale > 1.0))
			for action: StringName in [TitleModel.ACTION_CONTINUE,
					TitleModel.ACTION_NEW_GAME, TitleModel.ACTION_SETTINGS]:
				var button := root.title_screen.action_button(action)
				assert_ne(button, null, String(action))
				var wanted := button.get_combined_minimum_size()
				assert_true(wanted.y >= touch - 1.0,
						"%s is %d dp tall against a %d dp floor"
								% [String(action), int(wanted.y), int(touch)])
			_unmount(root)
