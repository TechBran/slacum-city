extends SimTest
## Doc 12 §2.17 / S12 — the scripted first fifteen minutes.
##
## Three layers, three kinds of test. `OnboardingModel` is pure, so every advance
## condition, the hard-gate rule, the resume and the skip are asserted headlessly
## with no scene at all. `CoachMark` and `OnboardingFlow` are mounted, because the
## thing worth asserting about them is geometric: which rectangle the cutout
## claims, and which touches it swallows. `BuildController`'s new grid category is
## checked against a real `CitySim`, because the whole point of the transformer
## card is that it turns doc 04's `E_UNSERVED` from a wall into a purchase — and
## the only honest way to assert that is to hit the wall and then walk through it.

const LOT_A := Vector2i(43, 40)   ## `tutorial_lot_a`, doc 09 §2.9.7 — UNSERVED
const LOT_B := Vector2i(45, 40)   ## `tutorial_lot_b` — served, the first house


func _cfg() -> UIConfig:
	return UIConfig.load_from_files()


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _model() -> OnboardingModel:
	var model := OnboardingModel.new(_cfg())
	model.set_regions({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	return model


func _started() -> OnboardingModel:
	var model := _model()
	model.start()
	model.take_actions()
	return model


## Feeds whatever the current step is waiting for, through `sink` — the model's
## own `feed` in the headless tests, the flow's in the mounted ones, so a mounted
## test exercises the drain-and-redraw path the real UI uses.
func _satisfy_via(model: OnboardingModel, sink: Callable) -> bool:
	match str(model.current().get("id", "")):
		"welcome", "payoff":
			return bool(sink.call({"kind": "ack"}))
		"look_around":
			sink.call({"kind": "camera", "focus": Vector3.ZERO, "zoom_t": 0.4})
			return bool(sink.call({"kind": "camera", "focus": Vector3(400.0, 0.0, 0.0),
					"zoom_t": 0.7}))
		"open_build":
			return bool(sink.call({"kind": "ui_opened", "path": "build_sheet"}))
		"place_house":
			return bool(sink.call({"kind": "command", "command": "place_building",
					"ok": true, "archetype": "house", "tile": LOT_B}))
		"unserved_wall":
			return bool(sink.call({"kind": "verdict", "code": "E_UNSERVED", "tile": LOT_A}))
		"place_transformer":
			return bool(sink.call({"kind": "command", "command": "place_grid_component",
					"ok": true, "archetype": "transformer",
					"tile": LOT_A + Vector2i(-1, 0)}))
		"blackout":
			return bool(sink.call({"kind": "sim_event", "event": "incident_created",
					"payload": {"incident_id": 1}}))
		"open_drawer":
			return bool(sink.call({"kind": "ui_opened", "path": "incident_drawer"}))
		"dispatch":
			return bool(sink.call({"kind": "command", "command": "dispatch_unit",
					"ok": true, "unit_id": 7}))
		"relight":
			return bool(sink.call({"kind": "sim_event", "event": "incident_resolved",
					"payload": {"incident_id": 1}}))
	return false


func _satisfy(model: OnboardingModel) -> bool:
	return _satisfy_via(model, model.feed)


func _walk_to(model: OnboardingModel, step_id: String) -> void:
	var guard := 0
	while str(model.current().get("id", "")) != step_id and model.is_active():
		guard += 1
		if guard > 32:
			break
		_satisfy(model)


func _walk_flow_to(flow: OnboardingFlow, step_id: String) -> void:
	var guard := 0
	while str(flow.model.current().get("id", "")) != step_id and flow.is_active():
		guard += 1
		if guard > 32:
			break
		_satisfy_via(flow.model, flow.feed)


# ===========================================================================
# The step table (doc 12 §2.17 + §3.1)
# ===========================================================================

func test_the_step_table_is_data_and_its_copy_is_authored() -> void:
	var cfg := _cfg()
	var block := cfg.section("onboarding")
	assert_false(block.is_empty(), "data/ui.json carries the onboarding section")
	var model := OnboardingModel.new(cfg)
	assert_true(model.step_count() >= 8, "the flow is the whole first fifteen minutes")
	var ids := model.step_ids()
	# The beats of §2.17 the shipped verbs can carry, in the doc's order.
	for expected: String in ["welcome", "open_build", "place_house", "unserved_wall",
			"place_transformer", "blackout", "open_drawer", "dispatch", "payoff"]:
		assert_true(ids.has(expected), "the table carries the %s step" % expected)
	assert_true(ids.find("unserved_wall") < ids.find("place_transformer"),
			"the wall is taught before its answer")
	assert_true(ids.find("place_transformer") < ids.find("blackout"),
			"the transformer exists before it fails")
	assert_true(ids.find("dispatch") < ids.find("relight"),
			"the crew rolls before the lights come back")

	var cap := int(UIConfig.get_num(block, "coach_text_max_chars", 90.0))
	var seen: Dictionary = {}
	for i in model.step_count():
		var step := model.step_at(i)
		var key := str(step.get("text_key", ""))
		assert_true(cfg.has_string(key), "%s resolves copy from the table (G-8)" % key)
		var text := cfg.t(key)
		assert_true(text.length() <= cap,
				"%s is %d chars, cap %d" % [key, text.length(), cap])
		assert_false(text.contains("{"), "%s leaves no placeholder unresolved" % key)
		assert_false(seen.has(str(step.get("id", ""))), "step ids are unique")
		seen[str(step.get("id", ""))] = true
	for key: String in ["ui_coach_skip", "ui_coach_got_it", "ui_coach_show_me",
			"ui_coach_step"]:
		assert_true(cfg.has_string(key), "the bubble's own copy is in the table: %s" % key)


func test_no_step_names_a_verb_the_sim_does_not_have() -> void:
	# §2.17's table assumes commands that have not shipped (player-drawn water
	# mains, land purchase from the sheet). A step that waits on one of those
	# would hang the tutorial forever, so the table may only name live commands.
	var live := ["place_building", "place_grid_component", "dispatch_unit"]
	var model := OnboardingModel.new(_cfg())
	for i in model.step_count():
		var advance: Dictionary = model.step_at(i).get("advance", {})
		for condition: Dictionary in _conditions(advance):
			if str(condition.get("kind", "")) != "command":
				continue
			assert_true(live.has(str(condition.get("command", ""))),
					"%s waits on a command CitySim has" % model.step_at(i).get("id", ""))


static func _conditions(advance: Dictionary) -> Array[Dictionary]:
	if str(advance.get("kind", "")) != "any_of":
		return [advance] as Array[Dictionary]
	var out: Array[Dictionary] = []
	for raw: Variant in (advance.get("conditions", []) as Array):
		if raw is Dictionary:
			out.append(raw)
	return out


# ===========================================================================
# Walking the machine
# ===========================================================================

func test_every_advance_condition_walks_the_flow_in_order() -> void:
	var model := _started()
	var order: Array[String] = []
	var guard := 0
	while model.is_active() and guard < 32:
		guard += 1
		order.append(str(model.current().get("id", "")))
		assert_true(_satisfy(model), "step %s advanced on its own condition"
				% order[order.size() - 1])
	assert_true(model.is_finished(), "the flow completed")
	assert_eq(order, model.step_ids(), "every step ran once, in table order")
	assert_eq(model.completed_ids(), model.step_ids())
	assert_false(model.skipped, "finishing is not skipping")


func test_a_wrong_command_never_completes_a_step() -> void:
	# Doc 12 test 16: a `command_accepted` failing the step's `match` filter does
	# not complete the step.
	var model := _started()
	_walk_to(model, "place_house")
	assert_eq(str(model.current()["id"]), "place_house")
	assert_false(model.feed({"kind": "command", "command": "place_building", "ok": true,
			"archetype": "store", "tile": LOT_B}), "the wrong archetype")
	assert_false(model.feed({"kind": "command", "command": "place_building", "ok": true,
			"archetype": "house", "tile": Vector2i(10, 10)}), "the wrong tile")
	assert_false(model.feed({"kind": "command", "command": "place_building", "ok": false,
			"archetype": "house", "tile": LOT_B}), "a refused command")
	assert_false(model.feed({"kind": "command", "command": "place_grid_component",
			"ok": true, "archetype": "house", "tile": LOT_B}), "the wrong command")
	assert_eq(str(model.current()["id"]), "place_house", "still waiting")
	assert_true(model.feed({"kind": "command", "command": "place_building", "ok": true,
			"archetype": "house", "tile": LOT_B}), "and the right one advances it")


func test_the_unserved_wall_advances_on_the_verdict_not_a_command() -> void:
	# The PLACE button is disabled while the preflight says no, so the player can
	# never issue the refused command. The teaching moment is the verdict itself.
	var model := _started()
	_walk_to(model, "unserved_wall")
	assert_false(model.feed({"kind": "verdict", "code": "E_FUNDS", "tile": LOT_A}),
			"a different blocker is a different lesson")
	assert_false(model.feed({"kind": "verdict", "code": "E_UNSERVED",
			"tile": Vector2i(20, 20)}), "on some other tile it teaches nothing")
	assert_true(model.feed({"kind": "verdict", "code": "E_UNSERVED", "tile": LOT_A}))
	assert_eq(str(model.current()["id"]), "place_transformer")


func test_the_unserved_wall_also_yields_to_a_player_who_worked_it_out() -> void:
	# `any_of`: opening the GRID tab is the same understanding, arrived at faster.
	var model := _started()
	_walk_to(model, "unserved_wall")
	assert_false(model.feed({"kind": "ui_opened", "path": "build_category_service"}))
	assert_true(model.feed({"kind": "ui_opened", "path": "build_category_grid"}))
	assert_eq(str(model.current()["id"]), "place_transformer")


func test_the_camera_step_needs_both_verbs_and_a_baseline() -> void:
	var model := _started()
	_walk_to(model, "look_around")
	# The first observation is the baseline, never the completion — a step that
	# begins mid-drag must not complete on the drag already in flight.
	assert_false(model.feed({"kind": "camera", "focus": Vector3(900.0, 0.0, 900.0),
			"zoom_t": 0.9}), "the first sample is the baseline")
	assert_false(model.feed({"kind": "camera", "focus": Vector3(1400.0, 0.0, 900.0),
			"zoom_t": 0.9}), "panning alone is half the lesson")
	assert_false(model.feed({"kind": "camera", "focus": Vector3(900.0, 0.0, 900.0),
			"zoom_t": 0.5}), "zooming alone is the other half")
	assert_true(model.feed({"kind": "camera", "focus": Vector3(1400.0, 0.0, 900.0),
			"zoom_t": 0.5}), "both, and the step is done")


func test_a_region_match_needs_a_resolved_tag() -> void:
	# A coach mark pointing at a lot the shell never resolved must not be
	# completable by accident.
	var model := OnboardingModel.new(_cfg())   # no set_regions()
	model.start()
	_walk_to(model, "place_house")
	assert_eq(str(model.current()["id"]), "place_house")
	assert_false(model.feed({"kind": "command", "command": "place_building", "ok": true,
			"archetype": "house", "tile": LOT_B}), "no region, no match")


func test_the_marked_lot_forgives_a_fat_finger_but_not_a_wrong_block() -> void:
	var model := _started()
	_walk_to(model, "place_house")
	var radius := int(model.number("region_radius_tiles", 1.0))
	assert_true(model.feed({"kind": "command", "command": "place_building", "ok": true,
			"archetype": "house", "tile": LOT_B + Vector2i(radius, 0)}),
			"one tile of slack is still the marked lot")


# ===========================================================================
# Timers and the action queue
# ===========================================================================

func test_the_scripted_failure_fires_on_the_clock_not_on_arrival() -> void:
	var model := _started()
	_walk_to(model, "blackout")
	assert_eq(str(model.current()["id"]), "blackout")
	model.take_actions()   # whatever the earlier steps asked for
	model.feed({"kind": "tick", "dt": 2.0})
	assert_true(model.take_actions().is_empty(), "and nothing fires early")
	model.feed({"kind": "tick", "dt": 5.0})
	var actions := model.take_actions()
	assert_eq(actions.size(), 1, "exactly one request")
	assert_eq(actions[0]["action"], OnboardingModel.ACTION_TRIGGER_INCIDENT)
	model.feed({"kind": "tick", "dt": 30.0})
	assert_true(model.take_actions().is_empty(), "the tutorial cooks one transformer")


func test_the_director_is_suppressed_for_the_whole_tutorial() -> void:
	var model := _model()
	model.start()
	var opening := model.take_actions()
	assert_eq(opening.size(), 1)
	assert_eq(opening[0]["action"], OnboardingModel.ACTION_SUPPRESS_DIRECTOR)
	assert_true(float((opening[0]["payload"] as Dictionary)["seconds"]) > 0.0)
	var guard := 0
	while model.is_active() and guard < 32:
		guard += 1
		_satisfy(model)
		model.take_actions()
	# §2.17: skipping or finishing "lifts suppression after 300 s".
	var closing := model.take_actions()
	assert_eq(closing.size(), 0, "already drained")
	model = _model()
	model.start()
	model.take_actions()
	model.skip()
	var after := model.take_actions()
	assert_eq(after.size(), 1)
	assert_eq(after[0]["action"], OnboardingModel.ACTION_RELEASE_DIRECTOR)
	assert_almost_eq(float((after[0]["payload"] as Dictionary)["seconds"]),
			model.number("director_suppress_after_s", 300.0), 0.001)


func test_hints_and_autohelp_appear_on_time() -> void:
	var model := _started()
	_walk_to(model, "open_build")
	assert_false(model.show_hint())
	assert_false(model.show_autohelp())
	model.feed({"kind": "tick", "dt": model.number("hint_after_s", 25.0)})
	assert_true(model.show_hint(), "the arrow and the pulse after 25 s")
	assert_false(model.show_autohelp())
	model.feed({"kind": "tick", "dt": model.number("autohelp_after_s", 60.0)})
	assert_true(model.show_autohelp(), "`Show me` after 60 s")
	assert_true(model.request_autohelp(), "and it queues the authored assist")
	var actions := model.take_actions()
	assert_eq(actions.size(), 1)
	assert_eq(actions[0]["action"], OnboardingModel.ACTION_OPEN_BUILD_SHEET,
			"it opens the menu — never the final commit")
	assert_eq(str(model.current()["id"]), "open_build",
			"the assist does not complete the step by itself")


func test_actions_drain_exactly_once() -> void:
	var model := _model()
	model.start()
	assert_eq(model.pending_action_count(), 1)
	assert_eq(model.take_actions().size(), 1)
	assert_eq(model.take_actions().size(), 0, "a drained queue stays drained")


# ===========================================================================
# Skip, resume, and never showing twice
# ===========================================================================

func test_skip_completes_everything_and_grants_nothing() -> void:
	var model := _started()
	_walk_to(model, "place_house")
	model.skip()
	assert_true(model.is_finished())
	assert_true(model.skipped)
	assert_false(model.is_active())
	assert_eq(model.completed_ids(), model.step_ids(), "all steps marked complete")
	assert_true(model.current().is_empty(), "and nothing is on screen")


func test_a_finished_tutorial_never_shows_again_until_it_is_reset() -> void:
	var model := _started()
	model.skip()
	assert_false(model.start(), "§2.17: it never shows again once done")
	assert_false(model.is_active())
	model.reset()
	assert_false(model.is_finished())
	assert_true(model.start(), "Settings ▸ Replay tutorial is the one door back in")
	assert_eq(str(model.current()["id"]), "welcome", "and it starts from the top")


func test_resume_mid_flow_from_the_save_section() -> void:
	var model := _started()
	_walk_to(model, "open_drawer")
	var state := model.capture_state()
	assert_eq(str(state["current_step"]), "open_drawer")
	assert_true(bool(state["active"]))
	assert_eq((state["completed"] as Array).size(), model.index_of("open_drawer"))

	var resumed := _model()
	resumed.restore_state(state)
	assert_true(resumed.is_active(), "a save taken mid-tutorial resumes it")
	assert_eq(str(resumed.current()["id"]), "open_drawer")
	assert_eq(resumed.completed_ids(), model.completed_ids())
	# And it keeps walking from there.
	assert_true(_satisfy(resumed))
	assert_eq(str(resumed.current()["id"]), "dispatch")


func test_a_restore_of_a_finished_tutorial_stays_finished() -> void:
	var model := _started()
	var guard := 0
	while model.is_active() and guard < 32:
		guard += 1
		_satisfy(model)
	var resumed := _model()
	resumed.restore_state(model.capture_state())
	assert_true(resumed.is_finished())
	assert_false(resumed.start())
	assert_true(resumed.current().is_empty())


func test_a_restore_drops_steps_this_build_no_longer_has() -> void:
	# §3.2's migration policy: unknown keys dropped, missing keys default, a save
	# can never invalidate a city.
	var model := _model()
	model.restore_state({"active": true, "current_step": "confirm_water",
			"completed": ["welcome", "collect_taxes", "look_around"], "skipped": false})
	assert_eq(model.completed_ids(), ["welcome", "look_around"],
			"the retired step id is dropped, the real ones survive")
	assert_true(model.is_active())
	assert_eq(str(model.current()["id"]), "open_build",
			"an unknown current step falls back to the first unfinished one")


func test_an_empty_state_is_a_fresh_city() -> void:
	var model := _model()
	model.restore_state({})
	assert_false(model.is_active())
	assert_false(model.is_finished())
	assert_true(model.start())


# ===========================================================================
# The coach mark (doc 12 §2.17's rendering + A3/A15)
# ===========================================================================

func _mount_mark() -> CoachMark:
	var mark := CoachMark.new()
	_tree().root.add_child(mark)
	mark.setup(_cfg())
	# Pin a phone-sized box: under `--headless` nothing lays the tree out, and the
	# geometry is the whole point of these four tests.
	mark.set_anchors_preset(Control.PRESET_TOP_LEFT)
	mark.size = Vector2(880.0, 400.0)
	return mark


func _drop(node: Node) -> void:
	_tree().root.remove_child(node)
	node.free()


func test_the_cutout_is_the_target_plus_the_documented_padding() -> void:
	var mark := _mount_mark()
	var block := _cfg().section("onboarding")
	var pad := UIConfig.get_num(block, "cutout_pad_dp", 8.0)
	var target := Rect2(200.0, 120.0, 64.0, 64.0)
	mark.present({"gate": "hard", "text": "x", "target": {}}, target)
	var cutout := mark.cutout_rect()
	assert_almost_eq(cutout.position.x, target.position.x - pad, 0.001)
	assert_almost_eq(cutout.size.x, target.size.x + pad * 2.0, 0.001, "8 dp both sides")
	assert_true(mark.is_showing())
	_drop(mark)


func test_a_hard_gate_claims_only_what_is_outside_the_cutout() -> void:
	var mark := _mount_mark()
	mark.present({"gate": "hard", "text": "Tap BUILD"}, Rect2(200.0, 120.0, 64.0, 64.0))
	assert_eq(mark.mouse_filter, Control.MOUSE_FILTER_STOP)
	assert_false(mark._has_point(Vector2(232.0, 152.0)),
			"the target keeps its own touches")
	assert_true(mark._has_point(Vector2(10.0, 10.0)), "everything else is swallowed")
	_drop(mark)


func test_a_soft_gate_claims_nothing_at_all() -> void:
	var mark := _mount_mark()
	mark.present({"gate": "soft", "text": "Watch"}, Rect2(200.0, 120.0, 64.0, 64.0))
	assert_eq(mark.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_false(mark._has_point(Vector2(10.0, 10.0)))
	assert_false(mark._has_point(Vector2(232.0, 152.0)))
	_drop(mark)


func test_a_hard_gate_with_no_target_degrades_to_soft() -> void:
	# The safe failure: a cutout-less hard gate would swallow the whole screen.
	var mark := _mount_mark()
	mark.present({"gate": "hard", "text": "Somewhere"}, Rect2())
	assert_false(mark._has_point(Vector2(10.0, 10.0)))
	_drop(mark)


func test_the_bubble_never_covers_what_it_points_at() -> void:
	var mark := _mount_mark()
	var target := Rect2(200.0, 120.0, 64.0, 64.0)
	mark.present({"gate": "soft", "text": "Place a house on the marked lot."}, target)
	var bubble := Rect2(mark.bubble().position, mark.bubble().size)
	assert_false(bubble.intersects(mark.cutout_rect()), "the bubble clears the cutout")
	assert_true(bubble.position.x >= 0.0 and bubble.end.x <= mark.size.x,
			"and stays on screen")
	assert_true(bubble.size.x <= UIConfig.get_num(_cfg().section("onboarding"),
			"bubble_max_w_dp", 240.0) + 0.5, "≤ 240 dp wide")
	_drop(mark)


func test_the_bubble_targets_pass_a3_and_a15() -> void:
	var mark := _mount_mark()
	mark.present({"gate": "soft", "text": "x", "show_ack": true, "show_autohelp": true,
			"ack_text": "GOT IT", "skip_text": "Skip tutorial"}, Rect2())
	var floor_dp := float(ThemeBuilder.touch_min_dp(_cfg(), 1.0, false))
	for button: Button in [mark.skip_button(), mark.ack_button(), mark.autohelp_button()]:
		assert_true(button.custom_minimum_size.x >= floor_dp
				and button.custom_minimum_size.y >= floor_dp,
				"%s is at least %d dp" % [button.name, int(floor_dp)])
		assert_false(button.tooltip_text.strip_edges().is_empty(),
				"%s carries an accessibility name" % button.name)
	assert_true(mark.ack_button().visible, "a card offers GOT IT")
	assert_true(mark.autohelp_button().visible, "and `Show me` once it is earned")
	_drop(mark)


func test_the_mark_hides_when_there_is_nothing_to_say() -> void:
	var mark := _mount_mark()
	mark.present({"gate": "soft", "text": "x"}, Rect2(10.0, 10.0, 40.0, 40.0))
	assert_true(mark.is_showing())
	mark.present({})
	assert_false(mark.is_showing())
	assert_false(mark.visible)
	assert_eq(mark.mouse_filter, Control.MOUSE_FILTER_IGNORE, "and it stops eating touches")
	_drop(mark)


# ===========================================================================
# The flow, mounted in the real scaffold
# ===========================================================================

func _mount() -> UIRoot:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var root: UIRoot = packed.instantiate()
	root.apply_content_scale = false
	_tree().root.add_child(root)
	root.initialize()
	return root


func test_the_coach_layer_carries_the_flow_and_shows_nothing_until_it_starts() -> void:
	var root := _mount()
	assert_ne(root.onboarding, null, "SafeArea/CoachLayer/Onboarding exists")
	assert_ne(root.onboarding.mark(), null)
	assert_false(root.onboarding.is_active())
	assert_false(root.onboarding.mark().is_showing(), "a fresh scene shows no coach mark")
	assert_eq(root.onboarding.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"the layer itself never eats a touch")
	assert_true(root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B}))
	assert_true(root.onboarding_active())
	assert_true(root.onboarding.mark().is_showing())
	_drop(root)


func test_a_ui_target_resolves_to_that_control_and_a_hidden_one_does_not() -> void:
	var root := _mount()
	var fab: Control = root.get_node("SafeArea/SheetLayer/BuildSheet/Fab")
	var rect := root.onboarding.target_rect(
			{"kind": "ui", "path": "SafeArea/SheetLayer/BuildSheet/Fab"})
	assert_eq(rect, fab.get_global_rect(), "the cutout is the FAB's own rectangle")
	assert_true(rect.size.x > 0.0)
	fab.visible = false
	assert_eq(root.onboarding.target_rect(
			{"kind": "ui", "path": "SafeArea/SheetLayer/BuildSheet/Fab"}), Rect2(),
			"a hidden target has no cutout")
	fab.visible = true
	assert_eq(root.onboarding.target_rect({"kind": "ui", "path": "SafeArea/Nope"}), Rect2())
	assert_eq(root.onboarding.target_rect({"kind": "none"}), Rect2())
	_drop(root)


func test_a_world_target_goes_through_the_shells_resolver() -> void:
	var root := _mount()
	root.set_onboarding_world_resolver(func(tag: String) -> Variant:
		return Vector2(400.0, 220.0) if tag == "tutorial_lot_b" else null)
	var rect := root.onboarding.target_rect({"kind": "world", "tag": "tutorial_lot_b"})
	assert_almost_eq(rect.get_center().x, 400.0, 0.001)
	assert_true(rect.size.x >= 48.0, "a world point becomes a 48 dp target (A3)")
	assert_eq(root.onboarding.target_rect({"kind": "world", "tag": "elsewhere"}), Rect2(),
			"a tag the shell cannot place has no cutout")
	_drop(root)


func test_the_screens_feed_their_own_observations() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	var model := root.onboarding.model
	_walk_flow_to(root.onboarding, "open_build")
	# No test-only hook: this is the sheet's own `sheet_toggled`, which the root
	# already listens to for the tutorial's sake and nothing else.
	root.build_sheet.open()
	assert_eq(str(model.current()["id"]), "place_house", "opening BUILD advanced the step")
	_walk_flow_to(root.onboarding, "open_drawer")
	root.incident_drawer.open()
	assert_eq(str(model.current()["id"]), "dispatch", "and so does opening the drawer")
	# The dispatch verdict comes back through the same call the picker already makes.
	root.report_dispatch_result(7, true)
	assert_eq(str(model.current()["id"]), "relight")
	_drop(root)


func test_a_refused_dispatch_does_not_advance_the_step() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	_walk_flow_to(root.onboarding, "dispatch")
	root.report_dispatch_result(7, false)
	assert_eq(str(root.onboarding.model.current()["id"]), "dispatch")
	_drop(root)


func test_sim_events_reach_the_step_machine_through_feed_events() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	_walk_flow_to(root.onboarding, "blackout")
	root.feed_events([{"type": &"building_completed", "building": 3},
			{"type": &"incident_created", "incident_id": 1}])
	assert_eq(str(root.onboarding.model.current()["id"]), "open_drawer",
			"the scripted failure is the one the tutorial waits for")
	_drop(root)


func test_the_root_serves_the_menu_actions_itself() -> void:
	var root := _mount()
	var seen: Array[StringName] = []
	root.onboarding_action.connect(func(action: StringName, _p: Dictionary) -> void:
		seen.append(action))
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	_walk_flow_to(root.onboarding, "place_transformer")
	# The step's `on_enter` asked for the GRID tab; the root owns the build sheet,
	# so it opened it before re-emitting for the shell.
	assert_true(root.build_sheet.is_open(), "the sheet opened itself")
	assert_true(seen.has(OnboardingModel.ACTION_OPEN_BUILD_CATEGORY),
			"and the shell still heard about it")
	assert_true(seen.has(OnboardingModel.ACTION_FOCUS_CAMERA),
			"the camera move is the shell's — the root only relays it")
	_drop(root)


func test_the_ui_save_section_round_trips_the_tutorial() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	_walk_flow_to(root.onboarding, "place_transformer")
	var state := root.capture_ui_state()
	assert_true(state.has("onboarding"), "doc 12 §3.2's `ui.onboarding` block")
	var block: Dictionary = state["onboarding"]
	assert_eq(str(block["current_step"]), "place_transformer")

	var other := _mount()
	other.restore_ui_state(state)
	assert_true(other.onboarding_active())
	assert_eq(str(other.onboarding.model.current()["id"]), "place_transformer")
	assert_true(other.onboarding.mark().is_showing(), "and the mark comes back up")
	_drop(other)
	_drop(root)


func test_a_completed_tutorial_does_not_come_back_on_load() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	root.onboarding.skip()
	var state := root.capture_ui_state()
	var other := _mount()
	other.restore_ui_state(state)
	assert_false(other.onboarding_active())
	assert_false(other.onboarding.mark().is_showing())
	assert_false(other.start_onboarding(), "and starting it again is refused")
	_drop(other)
	_drop(root)


func test_the_settings_row_is_the_one_way_back_in() -> void:
	var root := _mount()
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	root.onboarding.skip()
	assert_false(root.onboarding_active())
	var model: SettingsModel = root.settings_sheet.model
	assert_true(model.has_key("replay_tutorial"), "S9 carries the reset row")
	assert_eq(model.kind("replay_tutorial"), SettingsModel.KIND_TOGGLE)
	assert_false(model.value_bool("replay_tutorial"), "off by default")
	assert_true(_cfg().has_string("ui_settings_row_replay_tutorial"), "and it has copy")
	assert_false(model.device_scoped_keys().has("replay_tutorial"),
			"the tutorial is per-city, not per-device")

	root.settings_sheet.value_button("replay_tutorial").pressed.emit()
	assert_true(root.onboarding_active(), "the tutorial is running again")
	assert_eq(str(root.onboarding.model.current()["id"]), "welcome")
	assert_false(root.settings_sheet.model.value_bool("replay_tutorial"),
			"and the row switched itself back off — it is a door, not a preference")
	_drop(root)


func test_skipping_from_the_bubble_ends_it_everywhere() -> void:
	var root := _mount()
	var ended: Array[bool] = []
	root.onboarding_finished.connect(func(was_skipped: bool) -> void:
		ended.append(was_skipped))
	root.start_onboarding({"tutorial_lot_a": LOT_A, "tutorial_lot_b": LOT_B})
	root.onboarding.mark().skip_button().pressed.emit()
	assert_eq(ended, [true], "the shell hears it once")
	assert_false(root.onboarding_active())
	assert_false(root.onboarding.mark().is_showing())
	_drop(root)


# ===========================================================================
# The build sheet's grid category (doc 04 §2.1 through doc 12 §2.7)
# ===========================================================================

func test_the_sheet_lists_the_transformer_in_its_own_category() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.new(_cfg()))
	var cards := controller.cards()
	var transformer: Dictionary = {}
	for card: Dictionary in cards:
		if str(card["id"]) == "transformer":
			transformer = card
	assert_false(transformer.is_empty(), "the sheet offers a transformer")
	assert_eq(str(transformer["category"]), BuildController.CATEGORY_GRID)
	assert_eq(int(transformer["level"]), 1, "L1 is what the roster ships")
	assert_false(bool(transformer["locked"]), "no city level gates it")
	assert_true(int(transformer["cost"]) > 0, "priced from data/economy.json")
	assert_eq(transformer["footprint"], Vector2i(1, 1))
	assert_true(int(transformer["service_radius_tiles"]) > 0)
	assert_true(_cfg().has_string(str(transformer["name_key"])), "and it has a name (G-8)")
	assert_true(_cfg().has_string(BuildController.category_tab_key(
			BuildController.CATEGORY_GRID)), "the tab has copy too")
	# The grid tab sorts last: it is the tab you reach for once something said no.
	assert_eq(BuildController.CATEGORY_ORDER[BuildController.CATEGORY_ORDER.size() - 1],
			BuildController.CATEGORY_GRID)
	var last: Dictionary = cards[cards.size() - 1]
	assert_eq(str(last["category"]), BuildController.CATEGORY_GRID)


func test_placing_a_transformer_is_what_answers_the_unserved_wall() -> void:
	# The tutorial's central beat, end to end, through the same controller the
	# sheet uses: the marked lot refuses a house, a transformer fixes it, and the
	# refusal message says so in words (A14).
	var sim := CitySim.boot_from_files()
	var formatter := RequirementFormatter.new(_cfg())
	var controller := BuildController.new(sim, formatter)
	var lot_a: Vector2i = sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]
	var lot_b: Vector2i = sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]
	assert_eq(lot_a, LOT_A, "doc 09's tutorial lot is where this file thinks it is")
	assert_eq(lot_b, LOT_B)

	assert_true(bool(controller.enter("house")["ok"]))
	assert_eq(str(controller.move_to_tile(lot_b)["verdict"]), String(
			BuildController.VERDICT_VALID), "the served lot takes a house")
	var wall := controller.move_to_tile(lot_a)
	assert_eq(str(wall["verdict"]), String(BuildController.VERDICT_BLOCKED))
	assert_eq(StringName(str(wall["code"])), &"E_UNSERVED")
	assert_true(str((wall["failure"] as Dictionary)["body"]).to_lower().contains(
			"transformer"), "the reason names the fix, in words")
	assert_false(controller.can_confirm(), "and PLACE stays disabled")

	var entered := controller.enter_component("transformer")
	assert_true(bool(entered["ok"]))
	assert_true(controller.is_placing_component())
	var spot := lot_a + Vector2i(-1, 0)
	var quote := controller.move_to_tile(spot)
	assert_eq(str(quote["verdict"]), String(BuildController.VERDICT_VALID))
	assert_true(int((quote["params"] as Dictionary)["cost"]) > 0,
			"the quote includes the feeder lateral, not just the box")
	assert_eq(controller.placement_cost(), int((quote["params"] as Dictionary)["cost"]))
	var before := sim.treasury.balance
	var placed := controller.commit()
	assert_true(bool(placed["ok"]), "cmd_place_grid_component ran")
	assert_true(sim.treasury.balance < before, "and it was paid for")
	assert_false(controller.is_placing(), "placement mode ended")

	assert_true(sim.grid.would_serve(lot_a), "the dark lot is served now")
	var after := BuildController.new(sim, formatter)
	assert_true(bool(after.enter("house")["ok"]))
	assert_eq(str(after.move_to_tile(lot_a)["verdict"]), String(
			BuildController.VERDICT_VALID), "and the house that was refused fits")


func test_the_grid_card_refuses_a_level_the_roster_does_not_offer() -> void:
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.new(_cfg()))
	var refused := controller.enter_component("transformer", 9)
	assert_false(bool(refused["ok"]))
	assert_eq(refused["reason_code"], &"E_LEVEL_UNAVAILABLE")
	assert_false(controller.is_placing(), "a refused card never enters placement mode")
	assert_false(bool(controller.enter_component("flux_capacitor")["ok"]))
	assert_eq(controller.enter_component("flux_capacitor")["reason_code"],
			&"E_UNKNOWN_COMPONENT")


func test_a_building_card_still_places_a_building() -> void:
	# The grid path must not have changed the one that was already there.
	var sim := CitySim.boot_from_files()
	var controller := BuildController.new(sim, RequirementFormatter.new(_cfg()))
	assert_true(bool(controller.enter("house")["ok"]))
	assert_false(controller.is_placing_component())
	controller.move_to_tile(LOT_B)
	var result := controller.commit()
	assert_true(bool(result["ok"]))
	assert_true(str((result["payload"] as Dictionary)["sim_id"]).begins_with("P-"))
