extends SimTest
## `NOTIFICATION_OS_MEMORY_WARNING`, answered (PA-20).
##
## The signal existed for the whole life of the project and had **no listener**:
## `grep -rn "memory_warning\|NOTIFICATION_OS_MEMORY_WARNING" --include=*.gd .`
## found the declaration, its comment, the emit, and one assertion in
## `test_save_service.gd` that it does NOT trigger a save. Docs 11 and 13 both
## specify a response worth *"~40 % of VRAM in one frame"*; `main.gd._notification()`
## handled `WM_CLOSE_REQUEST` and nothing else. On a Fold running a large city
## beside other apps, the failure mode of not responding is a silent task kill.
##
## Two halves, tested where each lives: the governor takes the rung, the view
## gives back the memory. The shell's `_on_memory_warning` only orders them.

const RENDER_JSON := "res://data/render.json"
## A camera 250 m over chunk (0,0): doc 11 §2.5's MEDIUM band is 150 < d ≤ 420,
## and the chunk ~990 m east of it is FAR. Same pose `test_render_merge.gd` uses.
const MEDIUM_CAMERA := Vector3(64.0, 250.0, 64.0)


func _render_data() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_JSON)


func _governor(preset: String = "balanced") -> PerfGovernor:
	return PerfGovernor.new(_render_data(), preset)


# ----------------------------------------------------------------- the rung

func test_a_memory_warning_at_rung_zero_drops_far_cull_one_step() -> void:
	# The audit's own acceptance criterion, verbatim: "fire it on a governor at
	# rung 0 → rungs_applied() == 1, far_cull_m dropped one step".
	var governor := _governor()
	assert_eq(governor.rungs_applied(), 0, "a fresh governor is at the top")
	var before := governor.knob(PerfGovernor.MEMORY_KNOB)
	assert_true(governor.on_memory_warning(), "the step was taken")
	assert_eq(governor.rungs_applied(), 1)
	assert_true(governor.knob(PerfGovernor.MEMORY_KNOB) < before,
			"far_cull_m came down: %f -> %f"
					% [before, governor.knob(PerfGovernor.MEMORY_KNOB)])


func test_the_memory_response_takes_the_MEMORY_rung_not_the_next_one() -> void:
	# **The reason this is not `_step_down`.** The ladder's first rung is
	# `render_scale`, a frame-time lever that returns no memory at all; the
	# ladder is ordered by cost per millisecond, and Android is telling us about
	# bytes. A memory warning must not spend its one step on resolution.
	var governor := _governor()
	var scale_before := governor.knob("render_scale")
	governor.on_memory_warning()
	assert_almost_eq(governor.knob("render_scale"), scale_before, 1e-6,
			"render_scale is untouched")
	# And for contrast: the ordinary frame-time step DOES take render_scale.
	var other := _governor()
	other._step_down("frame_time")
	assert_true(other.knob("render_scale") < scale_before,
			"the ladder's own next rung is the resolution one")


func test_the_step_is_reported_with_its_own_reason() -> void:
	# The telemetry cue and the perf log both read `reason`; "memory_warning" is
	# how a capture tells a thermal step apart from a memory one.
	var governor := _governor()
	governor.on_memory_warning()
	var events := governor.drain_events()
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["type"]), "render_governor_stepped")
	assert_eq(String(events[0]["knob"]), PerfGovernor.MEMORY_KNOB)
	assert_eq(String(events[0]["reason"]), PerfGovernor.MEMORY_REASON)
	assert_eq(int(events[0]["direction"]), PerfGovernor.DIR_DOWN)


func test_a_second_warning_takes_a_second_step_and_then_the_floor_refuses() -> void:
	# `far_cull_m` steps -128 m from the preset's value down to a 600 m floor.
	# When there is no room left the answer is `false` — an honest "already at
	# the floor" rather than a claimed step the shell would log as a success.
	var governor := _governor()
	var steps := 0
	while governor.on_memory_warning():
		steps += 1
		assert_true(steps < 64, "the floor must be reachable")
	assert_true(steps >= 1, "at least one step existed at the top")
	assert_almost_eq(governor.knob(PerfGovernor.MEMORY_KNOB), 600.0, 0.001,
			"and it stopped exactly on the authored floor")
	assert_false(governor.on_memory_warning(), "the floor refuses")
	assert_eq(governor.rungs_applied(), steps, "a refusal applies no rung")


func test_a_memory_step_unwinds_like_any_other_rung() -> void:
	# It enters `_applied` out of ladder order, so the LIFO unwind must still
	# return it — otherwise a device that recovered would keep a 128 m tighter
	# cull for the rest of the session.
	var governor := _governor()
	var before := governor.knob(PerfGovernor.MEMORY_KNOB)
	governor.on_memory_warning()
	governor._step_up()
	assert_eq(governor.rungs_applied(), 0)
	assert_almost_eq(governor.knob(PerfGovernor.MEMORY_KNOB), before, 0.001)


func test_the_memory_knob_is_actually_on_the_ladder() -> void:
	# `MEMORY_KNOB` is a name; if a retune renamed the rung this would silently
	# become a no-op that reports `false` forever. Assert the pairing instead.
	var governor := _governor()
	var ids: Array = []
	for rung: Dictionary in governor.ladder:
		ids.append(String(rung.get("id", "")))
	assert_true(ids.has(PerfGovernor.MEMORY_KNOB),
			"data/render.json governor.knobs carries %s (has %s)"
					% [PerfGovernor.MEMORY_KNOB, ids])


# -------------------------------------------------------------------- the shed

func _model() -> RenderStateModel:
	var model := RenderStateModel.new(_render_data())
	var id := 1
	# Two chunks: one at the origin, one ~1 km east, so the MEDIUM pose puts one
	# in MEDIUM and the other in FAR.
	for spec: Array in [[Vector3(12.0, 0.0, 12.0), "house", 1],
			[Vector3(44.0, 0.0, 12.0), "house", 2],
			[Vector3(12.0, 0.0, 60.0), "office", 2],
			[Vector3(1064.0, 0.0, 40.0), "apartment", 3]]:
		model.add_building({"id": id, "archetype_id": StringName(spec[1]),
				"level": int(spec[2]), "family": "residential",
				"world_pos": spec[0], "block_id": "B",
				"transform": Transform3D(Basis.IDENTITY, spec[0] as Vector3),
				"occ_b": 0.8, "powered": true, "condition": 1.0})
		id += 1
	return model


func _view() -> CityView:
	var view := CityView.new()
	view.keep_medium_buffers = true
	view.keep_far_buffers = true
	view.setup(_model(), _render_data())
	return view


func test_shedding_frees_the_far_node_of_a_chunk_that_is_no_longer_far() -> void:
	var view := _view()
	view.refresh(0.1, 12.0, MEDIUM_CAMERA)
	assert_eq(view.far_chunk_count(), 1, "the distant chunk drew the shared box")
	# Move the camera on top of the far chunk: it is NEAR now, and its far node
	# is a MultiMesh nothing will submit again until the camera goes back.
	view.refresh(1.0, 12.0, Vector3(1030.0, 60.0, 40.0))
	var freed := view.shed_caches()
	assert_true(int(freed["far_nodes"]) >= 1, "the stale far node went: %s" % freed)
	view.free()


func test_shedding_keeps_what_is_on_screen() -> void:
	# The one thing a cache shed must never do is drop something being drawn.
	var view := _view()
	view.refresh(0.1, 12.0, MEDIUM_CAMERA)
	var calls_before := view.building_draw_calls()
	var stats_before := view.perf_stats()
	view.shed_caches()
	assert_eq(view.building_draw_calls(), calls_before,
			"the same nodes are still submitted after the shed")
	assert_eq(int(view.perf_stats()["far_calls"]), int(stats_before["far_calls"]))
	assert_eq(int(view.perf_stats()["merged_calls"]), int(stats_before["merged_calls"]))
	view.free()


func test_shedding_drops_the_retained_debug_buffers() -> void:
	var view := _view()
	view.refresh(0.1, 12.0, MEDIUM_CAMERA)
	assert_true(view.far_buffer(Vector2i(8, 0)).size() > 0,
			"keep_far_buffers retained one")
	var freed := view.shed_caches()
	assert_true(int(freed["far_buffers"]) + int(freed["medium_buffers"]) > 0,
			"and the shed gave them back: %s" % freed)
	assert_eq(view.far_buffer(Vector2i(8, 0)).size(), 0)
	view.free()


func test_shedding_is_idempotent() -> void:
	# A device under memory pressure gets the warning repeatedly. The second call
	# must be free rather than thrash.
	var view := _view()
	view.refresh(0.1, 12.0, MEDIUM_CAMERA)
	view.shed_caches()
	var second := view.shed_caches()
	assert_eq(int(second["far_nodes"]), 0)
	assert_eq(int(second["medium_nodes"]), 0)
	assert_eq(int(second["atlas_meshes"]), 0, "nothing was left unreferenced")
	view.free()


func test_shedding_before_setup_answers_a_census_rather_than_crashing() -> void:
	# `_renders_far` asks the model for a tier; a warning that arrives during
	# boot must not be the thing that kills the process.
	var view := CityView.new()
	var freed := view.shed_caches()
	assert_eq(int(freed["far_nodes"]), 0)
	assert_eq(int(freed["atlas_meshes"]), 0)
	view.free()


func test_the_shed_census_names_every_pool_it_can_free() -> void:
	var view := _view()
	var freed := view.shed_caches()
	for key: String in ["far_nodes", "medium_nodes", "atlas_meshes",
			"far_buffers", "medium_buffers"]:
		assert_true(freed.has(key), "the census is missing %s" % key)
	view.free()
