extends SimTest
## Doc 11 §2.13's adaptive governor (`game/render/perf_governor.gd`) and doc 13
## §2.8's thermal policy.
##
## The whole point of building the governor as a model rather than a Node is
## that its 5-second and 30-second holds are testable in microseconds. These
## tests drive it at an arbitrary "frame rate" and assert the ladder, the
## hysteresis, the latch and the protected list.

const BALANCED_BUDGET_MS := 1000.0 / 60.0   # 16.667 — presets.balanced.target_fps


func _governor(preset := "balanced") -> PerfGovernor:
	return PerfGovernor.new(PerfGovernor.load_config(), preset)


## Feed `seconds` of frames at `frame_ms` each, evaluating as the shell would.
func _run(g: PerfGovernor, frame_ms: float, seconds: float) -> int:
	var steps := 0
	var dt := 1.0 / 60.0
	var elapsed := 0.0
	while elapsed < seconds:
		g.submit_frame(frame_ms)
		if g.update(dt):
			steps += 1
		elapsed += dt
	return steps


# ------------------------------------------------------------------ the ladder

func test_ladder_is_doc11s_and_in_order() -> void:
	var g := _governor()
	var ids: Array = []
	for rung in g.ladder:
		ids.append(String((rung as Dictionary).get("id", "")))
	assert_eq(ids, ["render_scale", "particle_ratio", "far_cull_m", "street_lights",
			"preset_drop"], "§2.13's down order, verbatim")
	assert_almost_eq(g.budget_ms, BALANCED_BUDGET_MS, 1e-3,
			"the budget is 1000 / target_fps of the ACTIVE preset")
	assert_almost_eq(g.knob("render_scale"), 0.85, 1e-6, "balanced render_scale ceiling")
	assert_almost_eq(g.knob("far_cull_m"), 1200.0, 1e-6, "balanced far_cull ceiling")


func test_protected_knobs_are_never_on_the_ladder() -> void:
	var g := _governor()
	assert_eq(g.protected, ["emissive", "blackout", "glow_enabled"],
			"§2.13's protected list, from data/render.json")
	assert_eq(str(g.assert_protected_knobs()), str(PackedStringArray()),
			"no rung names a protected knob — the signature moment cannot degrade")


# ------------------------------------------------------------- stepping down

func test_step_down_waits_out_the_five_second_hold() -> void:
	var g := _governor()
	var hot := BALANCED_BUDGET_MS * 1.30   # over 1.25x, so it counts
	# Four seconds is not yet five: the reflex must not fire on a short spike.
	assert_eq(_run(g, hot, 4.0), 0, "a 4 s spike costs the player nothing")
	assert_eq(g.rungs_applied(), 0)
	assert_almost_eq(g.knob("render_scale"), 0.85, 1e-6, "still at the preset ceiling")
	# The fifth second does.
	assert_eq(_run(g, hot, 1.5), 1, "the hold expires and one rung is taken")
	assert_eq(g.rungs_applied(), 1)
	assert_almost_eq(g.knob("render_scale"), 0.80, 1e-6, "render_scale -0.05, the first rung")


func test_a_frame_inside_the_deadband_steps_nothing() -> void:
	var g := _governor()
	# 1.10x budget: over the target, under the 1.25x trigger. This is the band
	# the governor must sit still in, or every device oscillates forever.
	assert_eq(_run(g, BALANCED_BUDGET_MS * 1.10, 60.0), 0, "no step down")
	assert_eq(g.rungs_applied(), 0)
	# ...and 0.9x is under budget but over the 0.80x step-up trigger.
	var h := _governor()
	assert_eq(_run(h, BALANCED_BUDGET_MS * 0.90, 60.0), 0, "and no step up")


func test_the_ladder_walks_every_rung_and_stops_at_the_floors() -> void:
	var g := _governor()
	var hot := BALANCED_BUDGET_MS * 2.0
	_run(g, hot, 400.0)
	assert_true(g.at_floor(), "a sustained 2x overrun spends the whole ladder")
	assert_almost_eq(g.knob("render_scale"), 0.60, 1e-6, "render_scale floor")
	assert_true(g.knob("particle_ratio") <= 0.30 + 1e-6, "particle_ratio floor")
	assert_almost_eq(g.knob("street_lights"), 4.0, 1e-6, "street_lights floor")
	assert_eq(g.preset, "performance", "and the last rung drops the preset")
	assert_true(g.preset_latched(), "which latches for the session")
	# far_cull's floor is 600, but the preset drop re-bases its ceiling to
	# Performance's 900 — the governor may never RAISE a knob by stepping down.
	assert_true(g.knob("far_cull_m") <= 900.0 + 1e-6,
			"the dropped preset's cull is a ceiling, not a target (%.0f)"
			% g.knob("far_cull_m"))


func test_preset_drop_latches_and_never_steps_back_up() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 2.0, 400.0)
	assert_eq(g.preset, "performance")
	var rungs := g.rungs_applied()
	# Now the device is idle for ten minutes. Everything else may come back.
	_run(g, 4.0, 600.0)
	assert_true(g.rungs_applied() < rungs, "the cheap rungs are restored")
	assert_eq(g.preset, "performance", "but the preset drop is latched (§2.13)")
	assert_true(g.preset_latched())


# --------------------------------------------------------------- stepping up

func test_step_up_waits_thirty_seconds_and_undoes_lifo() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 1.30, 6.0)
	assert_eq(g.rungs_applied(), 1, "one rung down")
	assert_almost_eq(g.knob("render_scale"), 0.80, 1e-6)
	# 20 s of idle is not 30.
	_run(g, 4.0, 20.0)
	assert_eq(g.rungs_applied(), 1, "restoring quality is a 30 s decision, not a reflex")
	_run(g, 4.0, 12.0)
	assert_eq(g.rungs_applied(), 0, "and then it comes back")
	assert_almost_eq(g.knob("render_scale"), 0.85, 1e-6, "exactly to the preset ceiling")


func test_step_up_never_overshoots_the_preset_ceiling() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 1.30, 6.0)
	_run(g, 2.0, 600.0)   # a very long idle
	assert_eq(g.rungs_applied(), 0)
	assert_almost_eq(g.knob("render_scale"), 0.85, 1e-6, "never above the preset")
	assert_almost_eq(g.knob("far_cull_m"), 1200.0, 1e-6)
	assert_almost_eq(g.knob("particle_ratio"), 1.0, 1e-6)


func test_a_single_stutter_does_not_cost_quality() -> void:
	# The realistic case: 59 good frames and one 60 ms hitch, forever. p95 of a
	# 120-frame window sees at most 6 hitches, so the p95 must stay under the
	# trigger and the picture must never move.
	var g := _governor()
	var dt := 1.0 / 60.0
	for i in 3600:
		g.submit_frame(60.0 if i % 60 == 0 else 10.0)
		g.update(dt)
	assert_eq(g.rungs_applied(), 0, "one hitch a second never steps the ladder down")
	assert_true(g.p95_ms() < BALANCED_BUDGET_MS * 1.25,
			"p95 %.1f stays under the trigger" % g.p95_ms())


# ------------------------------------------------------------------- thermal

func test_thermal_severe_steps_down_without_waiting() -> void:
	var g := _governor()
	g.set_thermal_status(PerfGovernor.THERMAL_SEVERE)
	# Frame time is perfectly fine — it looks fine because the heat has not been
	# paid for yet. One evaluation interval is all it takes.
	var steps := _run(g, 8.0, 1.5)
	assert_true(steps >= 1, "SEVERE bypasses the 5 s hold")
	assert_true(g.rungs_applied() >= 1)
	assert_eq(g.target_fps(), 30, "doc 13 §2.8: SEVERE caps the frame rate at 30")


func test_thermal_moderate_blocks_recovery_but_does_not_step_down() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 1.30, 6.0)
	assert_eq(g.rungs_applied(), 1)
	g.set_thermal_status(PerfGovernor.THERMAL_MODERATE)
	_run(g, 4.0, 120.0)
	assert_eq(g.rungs_applied(), 1, "a warm device keeps what it has — no step up")
	assert_eq(g.target_fps(), 45, "doc 13 §2.8: MODERATE caps at 45")


func test_thermal_critical_latches_the_cheapest_preset_at_once() -> void:
	var g := _governor("high")
	assert_eq(g.preset, "high")
	g.set_thermal_status(PerfGovernor.THERMAL_CRITICAL)
	assert_true(_run(g, 8.0, 0.1) >= 1, "no evaluation interval is waited out")
	assert_eq(g.preset, "balanced", "one preset down, latched")
	assert_true(g.preset_latched())
	assert_eq(g.target_fps(), 30)


func test_cooling_is_hysteretic() -> void:
	var g := _governor()
	g.set_thermal_status(PerfGovernor.THERMAL_SEVERE)
	assert_eq(g.thermal_status(), PerfGovernor.THERMAL_SEVERE, "heating applies at once")
	g.set_thermal_status(PerfGovernor.THERMAL_NONE)
	assert_eq(g.thermal_status(), PerfGovernor.THERMAL_SEVERE,
			"cooling does not — the device may be sitting on a boundary")
	_run(g, 8.0, g.thermal_recover_s - 5.0)
	assert_eq(g.thermal_status(), PerfGovernor.THERMAL_SEVERE, "…still holding at 25 s")
	_run(g, 8.0, 8.0)
	assert_eq(g.thermal_status(), PerfGovernor.THERMAL_NONE, "…and releases after 30 s")


# ------------------------------------------------------------- the switch off

func test_auto_quality_off_freezes_the_knobs_where_they_are() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 1.30, 6.0)
	assert_almost_eq(g.knob("render_scale"), 0.80, 1e-6)
	g.enabled = false
	_run(g, BALANCED_BUDGET_MS * 3.0, 120.0)
	assert_almost_eq(g.knob("render_scale"), 0.80, 1e-6,
			"off means FROZEN, not reset — a quality jump is what the toggle must not do")
	assert_eq(g.rungs_applied(), 1)


func test_the_player_picking_a_preset_resets_the_ladder() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 2.0, 60.0)
	assert_true(g.rungs_applied() > 0)
	g.reset("high")
	assert_eq(g.rungs_applied(), 0, "the player's choice outranks the ladder")
	assert_almost_eq(g.knob("render_scale"), 1.0, 1e-6, "high's ceiling")
	assert_almost_eq(g.knob("far_cull_m"), 1500.0, 1e-6)
	assert_false(g.preset_latched(), "and clears a latched drop")


# ------------------------------------------------------------------ telemetry

func test_every_step_is_reported_on_the_event_stream() -> void:
	var g := _governor()
	_run(g, BALANCED_BUDGET_MS * 1.30, 6.0)
	var events := g.drain_events()
	assert_eq(events.size(), 1, "one step, one event")
	var e: Dictionary = events[0]
	assert_eq(String(e["type"]), "render_governor_stepped", "§2.15's telemetry name")
	assert_eq(String(e["knob"]), "render_scale")
	assert_eq(int(e["direction"]), PerfGovernor.DIR_DOWN)
	assert_almost_eq(float(e["from"]), 0.85, 1e-6)
	assert_almost_eq(float(e["to"]), 0.80, 1e-6)
	assert_eq(g.drain_events().size(), 0, "and draining empties it")


func test_perf_line_matches_doc11_7_4() -> void:
	var g := _governor()
	for i in 120:
		g.submit_frame(17.1)
	g.update(1.0)
	var line := g.perf_line(62.0, {"cpu_ms": 3.8, "gpu_ms": 12.1, "draw_calls": 214,
			"primitives": 486133, "vram_mb": 298, "static_mem_mb": 141,
			"chunks": 14, "near_chunks": 3, "instances": 4120, "lights": 12})
	assert_true(line.begins_with("PERF t=62.0 "), "the grep anchor §7.4 documents")
	for token in ["fps=", "p95=", "cpu=3.8", "gpu_est=12.1", "dc=214", "prim=486133",
			"vram=298", "static_mem=141", "chunks=14", "near=3", "inst=4120",
			"lights=12", "preset=balanced", "knob=0"]:
		assert_true(line.contains(token), "PERF line carries %s (%s)" % [token, line])


# --------------------------------------------------------- the model's hooks

func test_far_cull_knob_reaches_the_lod_arithmetic() -> void:
	var model := RenderStateModel.new(RenderStateModel.load_config(), "balanced")
	assert_almost_eq(model.far_cull_m, 1200.0, 1e-6)
	assert_eq(model.raw_tier(1100.0), RenderStateModel.TIER_FAR, "1.1 km is drawn")
	model.apply_governor({"far_cull_m": 944.0})
	assert_almost_eq(model.far_cull_m, 944.0, 1e-6, "the governor's value is in force")
	assert_eq(model.raw_tier(1100.0), RenderStateModel.TIER_CULLED,
			"and the same chunk is now culled — the step actually saves the calls")


func test_the_governor_can_never_raise_the_cull_past_the_preset() -> void:
	var model := RenderStateModel.new(RenderStateModel.load_config(), "performance")
	assert_almost_eq(model.far_cull_m, 900.0, 1e-6, "performance far_cull")
	model.apply_governor({"far_cull_m": 5000.0})
	assert_almost_eq(model.far_cull_m, 900.0, 1e-6,
			"clamped to the preset ceiling, not trusted")


func test_tier_census_counts_what_the_view_submits() -> void:
	var model := RenderStateModel.new(RenderStateModel.load_config(), "balanced")
	model.set_chunk_tier(Vector2i(0, 0), RenderStateModel.TIER_NEAR)
	model.set_chunk_tier(Vector2i(1, 0), RenderStateModel.TIER_MEDIUM)
	model.set_chunk_tier(Vector2i(2, 0), RenderStateModel.TIER_FAR)
	model.set_chunk_tier(Vector2i(3, 0), RenderStateModel.TIER_CULLED)
	var census := model.tier_census()
	assert_eq(int(census["near"]), 1)
	assert_eq(int(census["medium"]), 1)
	assert_eq(int(census["far"]), 1)
	assert_eq(int(census["culled"]), 1)
