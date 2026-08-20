extends SimTest
## The knobs the Fold-6 measurement pass authored, and the telemetry it wired.
##
## Doc 11 §2.13, "The Fold 6 pass". Three surfaces are covered here and nothing
## else is: the asphalt fragment ladder (`road_surface.detail` and the per-preset
## `road_detail` ceiling), the pad-shadow default (`power_infra.pad_shadows`),
## and `PerfTelemetry`, which is the thing that turns
## `PerfGovernor.perf_line()` — shipped in Wave 6 and called by nothing until now
## — into a line a phone actually prints.
##
## What is asserted is the CONTRACT, not the tuning. That the ladder exists, that
## it clamps downward only, that the shipped ceiling is the authored look, that a
## preset may lower it and may not raise it past the project ceiling. The rung
## each preset takes is a measurement (doc 11 §2.13) and moving it is a ruling,
## not a bug — so the values themselves are checked only where the DEFAULT is
## load-bearing: rung 2 is the picture the street pass shipped, and any file that
## quietly lowered it would change the game's look with no test going red.

const RENDER := "res://data/render.json"


func _render() -> Dictionary:
	return StarterCityLoader.read_json(RENDER)


# ------------------------------------------------- the asphalt fragment ladder

func test_road_detail_default_is_the_shipped_look() -> void:
	var cfg: Dictionary = _render().get("road_surface", {})
	assert_true(cfg.has("detail"), "road_surface.detail is authored, not implied")
	assert_eq(int(cfg["detail"]), 2,
			"rung 2 IS the street pass's picture — doc 11 §2.13 proves it "
			+ "pixel-identical to the pre-ladder shader at Z0")


func test_road_detail_reaches_the_view() -> void:
	var view := RoadSurfaceView.new()
	view.setup(_render())
	assert_eq(view.detail_ceiling, 2, "the project ceiling is read from the file")
	assert_eq(view.detail, 2, "and the live rung starts at it")


func test_the_ladder_only_ever_goes_down() -> void:
	var view := RoadSurfaceView.new()
	view.setup(_render())
	view.set_detail(1)
	assert_eq(view.detail, 1, "a lower rung is taken")
	view.set_detail(0)
	assert_eq(view.detail, 0, "and a lower one again")
	view.set_detail(2)
	assert_eq(view.detail, 2, "back up to the ceiling is allowed")
	view.detail_ceiling = 1
	view.set_detail(2)
	assert_eq(view.detail, 1,
			"but never PAST the ceiling — the governor may spend quality, "
			+ "never invent it")
	view.set_detail(-4)
	assert_eq(view.detail, 0, "and never below rung 0")


func test_every_preset_names_a_legal_rung() -> void:
	var presets: Dictionary = _render().get("presets", {})
	assert_false(presets.is_empty(), "the preset table exists")
	for name: Variant in presets:
		var row: Dictionary = presets[name]
		if not row.has("road_detail"):
			continue   # a preset without the row keeps road_surface.detail
		var rung := int(row["road_detail"])
		assert_true(rung >= 0 and rung <= 2,
				"preset %s asks for road_detail %d, outside 0..2" % [name, rung])


func test_a_preset_ceiling_is_applied_and_clamps() -> void:
	var data := _render().duplicate(true)
	# A preset that asks for rung 1 must GET rung 1 — this is the Performance
	# tier's shipped arrangement, and the one that would silently do nothing if
	# `set_preset` forgot to re-apply the live rung.
	((data["presets"] as Dictionary)["balanced"] as Dictionary)["road_detail"] = 1
	var view := RoadSurfaceView.new()
	view.setup(data)
	view.set_preset("balanced", data)
	assert_eq(view.detail_ceiling, 1, "the preset row is the ceiling")
	assert_eq(view.detail, 1, "and the live rung followed it down")
	view.set_detail(2)
	assert_eq(view.detail, 1, "asking for 2 under a 1 ceiling gets 1")


func test_an_unknown_preset_falls_back_to_the_project_ceiling() -> void:
	var data := _render()
	var view := RoadSurfaceView.new()
	view.setup(data)
	view.set_preset("no_such_tier", data)
	assert_eq(view.detail_ceiling,
			int((data.get("road_surface", {}) as Dictionary).get("detail", 2)),
			"a tier with no row keeps road_surface.detail rather than 0")


func test_the_shader_carries_the_uniform_the_file_authors() -> void:
	# The knob is only a knob if the shader has somewhere to put it. A rename on
	# one side of this pair is invisible until a device session measures two
	# identical arms and calls the ladder free.
	var path := "res://game/shaders/road_surface.gdshader"
	assert_true(ResourceLoader.exists(path), "the asphalt shader is on disk")
	var text := FileAccess.get_file_as_string(path)
	assert_true(text.contains("uniform int detail"),
			"road_surface.gdshader declares the `detail` uniform")
	assert_true(text.contains("if (detail >= 1 && cw_mask > 0.5)"),
			"rung 0 drops the zebra loop — and since RR-42 the same gate also "
			+ "early-outs on the crosswalk mask, so a NON-JUNCTION tile does "
			+ "not pay for a loop that would paint nothing. Both halves are "
			+ "asserted together on purpose: dropping either one silently "
			+ "costs 61-69 % of the zebra term back")
	assert_true(text.contains("if (detail >= 2)"),
			"rung 1 drops the wear terms")


# --------------------------------------------------------------- pad shadows

func test_pad_shadows_are_authored_and_on() -> void:
	var cfg: Dictionary = _render().get("power_infra", {})
	assert_true(cfg.has("pad_shadows"),
			"power_infra.pad_shadows is authored — doc 11 §2.13 priced it at "
			+ "+1 draw call and no measurable GPU time")
	assert_true(bool(cfg["pad_shadows"]),
			"and it ships ON: a 1.5 m cabinet with no contact shadow at Z0 "
			+ "reads as a decal on the pavement")


# ----------------------------------------------------------------- telemetry

func _governor() -> PerfGovernor:
	return PerfGovernor.new(_render(), "balanced")


func test_telemetry_takes_its_cadence_from_the_file() -> void:
	var t := PerfTelemetry.new(_render())
	var authored := float((_render().get("governor", {}) as Dictionary).get(
			"perf_log_interval_s", -1.0))
	assert_true(authored > 0.0, "governor.perf_log_interval_s is authored")
	assert_almost_eq(t.interval_s, authored, 1e-6,
			"and PerfTelemetry runs on it rather than on a constant")


func test_telemetry_emits_on_the_interval_and_not_before() -> void:
	var t := PerfTelemetry.new(_render())
	t.print_lines = false
	var g := _governor()
	for i in 120:
		g.submit_frame(16.0)
	var interval := t.interval_s
	# Ten frames that together fall one tick short of the interval.
	for i in 10:
		assert_eq(t.tick(interval * 0.099, g), "",
				"nothing is emitted before the interval elapses")
	assert_eq(t.lines_emitted, 0, "and the counter agrees")
	var line := t.tick(interval * 0.02, g)
	assert_true(line.begins_with("PERF t="),
			"the crossing frame emits doc 11 §7.4's line (%s)" % line)
	assert_eq(t.lines_emitted, 1, "exactly one line per crossing")
	assert_eq(t.last_line, line, "and the last line is kept for a test to read")


func test_telemetry_clock_is_injected_not_wall() -> void:
	# Every `t=` in the log has to be a function of the deltas handed in, or two
	# runs of the same scripted session produce different logs and a device
	# capture cannot be compared with the one before it.
	var g := _governor()
	for i in 120:
		g.submit_frame(16.0)
	var a := PerfTelemetry.new(_render())
	var b := PerfTelemetry.new(_render())
	a.print_lines = false
	b.print_lines = false
	var la := ""
	var lb := ""
	for i in 8:
		la = a.tick(0.5, g)
		lb = b.tick(0.5, g)
	assert_eq(la.split(" ")[1], lb.split(" ")[1],
			"two telemetries fed the same deltas report the same t=")


func test_telemetry_without_a_governor_is_silent() -> void:
	var t := PerfTelemetry.new(_render())
	t.print_lines = false
	assert_eq(t.tick(10.0, null), "", "no governor, no line, no crash")


# ------------------------------------------------------- save/load stopwatch

func test_save_service_times_both_directions() -> void:
	# The numbers themselves are a measurement (doc 11 §2.13); what is asserted
	# is that the instrument exists and that both wrappers actually run, because
	# a stopwatch that is never started reports 0.0 and reads like a fast phone.
	var service := SaveService.new()
	service.base_dir = "user://test_device_knobs"
	service.log_io = false
	var sim := _sim()
	assert_true(service.save_slot(sim, 1, "manual").size() > 0, "the save lands")
	assert_true(service.last_save_ms > 0.0,
			"and it is timed (%f ms)" % service.last_save_ms)
	assert_true(service.load_slot(sim, 1), "the load lands")
	assert_true(service.last_load_ms > 0.0,
			"and it is timed (%f ms)" % service.last_load_ms)
	service.delete_slot(1)


func _sim() -> CitySim:
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json("res://data/starter_city.json"),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim
