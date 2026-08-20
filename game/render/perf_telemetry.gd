class_name PerfTelemetry
extends RefCounted
## The engine-facing half of doc 11 §7.4's `PERF` line — the thing that was
## missing when the first Fold 6 session went looking for it.
##
## `PerfGovernor.perf_line()` has existed since Wave 6 and is covered by
## `tests/test_perf_governor.gd`; **nothing ever called it.** §7.4 documents
## `adb logcat -s godot:V | grep '^PERF'` as the on-device instrument and
## `tools/bench_device.sh` is written against it, so a device run on the shipped
## build collected an empty CSV and its own summariser printed
## "NO PERF LINES — check the PRE-FLIGHT notes". That is a measurement hole, not
## a bug in the harness: the line was authored, tested, and never wired.
##
## This is the wiring, and it is a separate file for the reason `PerfGovernor`
## is what it is: the governor is a **model** with no Node and no engine
## singleton, which is what lets its 5 s and 30 s holds be driven in
## microseconds by a headless test. Reading `Performance` monitors and a
## viewport's measured render time is engine work. Keeping the two apart means
## the governor stays testable and this stays one small object with one job.
##
## Node-free by choice (`RefCounted`), clock-injected through `tick(delta)` —
## no `Time`, no `Engine.get_frames_drawn()`, so a test can drive an hour of
## telemetry in a loop and get exactly the lines a phone would print.
##
## Usage (the whole integration; see the branch report's main.gd snippet):
##
##     perf_telemetry = PerfTelemetry.new(render_data)
##     perf_telemetry.set_viewport(get_viewport().get_viewport_rid())
##     perf_telemetry.set_census_source(func() -> Dictionary:
##         return render_model.tier_census())
##     perf_telemetry.set_instance_source(func() -> int:
##         return render_model.building_count())
##     # ...once per frame, after perf_governor.submit_frame():
##     perf_telemetry.tick(delta, perf_governor)

## Seconds between lines. `data/render.json` → `governor.perf_log_interval_s`,
## which §7.4's example line (`t=62.0`) is written against.
var interval_s: float = 2.0
## Printing is on by default because the line IS the instrument. A test that
## drives thousands of frames turns it off and reads `last_line` instead.
var print_lines: bool = true
## The most recent line, whether or not it was printed.
var last_line: String = ""
## Lines emitted since construction — what a test asserts a cadence against.
var lines_emitted: int = 0

var _viewport: RID = RID()
var _census: Callable = Callable()
var _lights: Callable = Callable()
var _instances: Callable = Callable()
var _elapsed_s: float = 0.0
var _since_line_s: float = 0.0


func _init(render_data: Dictionary = {}) -> void:
	var governor: Dictionary = render_data.get("governor", {})
	interval_s = maxf(0.1, float(governor.get("perf_log_interval_s", interval_s)))


## The viewport whose CPU/GPU render time the line reports. Measurement is OFF
## on every viewport by default and the server returns 0.0 until it is asked
## for — so this enables it, and a caller that never sets a viewport gets
## `cpu=0.0 gpu_est=0.0` rather than a plausible-looking wrong number.
func set_viewport(rid: RID) -> void:
	_viewport = rid
	if _viewport.is_valid():
		RenderingServer.viewport_set_measure_render_time(_viewport, true)


## `func() -> Dictionary` returning `RenderStateModel.tier_census()`. The chunk
## and NEAR columns are the renderer's own bookkeeping and no engine monitor
## carries them.
func set_census_source(census: Callable) -> void:
	_census = census


## `func() -> int` returning the live street-omni count. Optional; without it
## the `lights=` column reports 0 rather than the preset's authored ceiling,
## because the ceiling is not a measurement.
func set_light_source(lights: Callable) -> void:
	_lights = lights


## `func() -> int` returning resident BUILDING instances —
## `RenderStateModel.building_count()`. Optional, and deliberately not stood in
## for by `Performance.OBJECT_COUNT`: that counts every `Object` the engine
## holds, which on this shell is thousands of UI nodes and would put a number in
## §7.4's `inst=` column that looks like an answer and is not one.
func set_instance_source(instances: Callable) -> void:
	_instances = instances


## One frame. Returns the line when this frame crossed the interval, "" the rest
## of the time. Emitting on the crossing rather than on a frame counter is what
## keeps the cadence honest when the frame rate is the thing being measured.
func tick(delta: float, governor: PerfGovernor) -> String:
	_elapsed_s += delta
	_since_line_s += delta
	if _since_line_s < interval_s or governor == null:
		return ""
	_since_line_s = 0.0
	last_line = governor.perf_line(_elapsed_s, stats())
	lines_emitted += 1
	if print_lines:
		print(last_line)
	return last_line


## Everything §7.4's line carries that the governor cannot see for itself.
func stats() -> Dictionary:
	var out := {
		"draw_calls": int(Performance.get_monitor(
				Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(
				Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vram_mb": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
				/ 1048576.0),
		"static_mem_mb": int(Performance.get_monitor(Performance.MEMORY_STATIC)
				/ 1048576.0),
	}
	if _viewport.is_valid():
		out["cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(_viewport)
		out["gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(_viewport)
	if _census.is_valid():
		var census: Variant = _census.call()
		if census is Dictionary:
			var c: Dictionary = census
			out["chunks"] = int(c.get("near", 0)) + int(c.get("medium", 0)) \
					+ int(c.get("far", 0))
			out["near_chunks"] = int(c.get("near", 0))
	if _lights.is_valid():
		out["lights"] = int(_lights.call())
	if _instances.is_valid():
		out["instances"] = int(_instances.call())
	return out
