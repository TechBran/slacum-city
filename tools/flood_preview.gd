extends Node
## Screenshots STANDING WATER over the real game (doc 07 §2.4, A91-D-26).
##
## Like `tools/power_infra_preview.gd` this instantiates `game/main.tscn` — the
## real shell, the real sim, the real camera — rather than assembling a harness
## scene, and for the same reason: the question about a flooded street is
## whether it reads AS a flooded street, on the asphalt, under the streetlights,
## at the zoom a player actually uses. A backdrop cannot answer that.
##
## It also **is the integration test for the shell hook.** `FloodView` is
## attached here with exactly the lines `game/main.gd` needs (report to the
## lead, §3), against the live `main.tscn` instance — so if the snippet were
## wrong, this harness would be the thing that failed.
##
## The flood is forced through doc 07's own debug lever and nothing else:
## `WeatherSystem.debug_force_weather(state, intensity, duration)` rewrites the
## committed timeline exactly the way the Director does, so the precipitation
## that fills the flood field is real precipitation and every band the shot
## shows was crossed by `FloodField.integrate` on the utilities cadence. There
## is no "paint the water" switch here, deliberately.
##
##   godot --path . tools/flood_preview.tscn -- --phase=peak --hour=21 \
##       --out=/tmp/flood_peak_night.png
##
##   --phase=      rise | peak | recede | dry   (default peak)
##                 rise   ~0.9 game-hours of THUNDERSTORM: the standing-water
##                        band, puddles joining up
##                 peak   ~2.6 game-hours: past 350 mm, the impassable band,
##                        the sheet standing over the kerb
##                 recede CLEAR after the peak, drained back through the bands
##                        with the dark-wet tail still on the asphalt
##                 dry    no weather forced at all — the control shot
##   --hours=H     override the phase's game-hours of rain
##   --drain=H     game-hours of CLEAR after the rain (recede only)
##   --hour=H      wall the shell's clock to this hour before shooting
##   --zoom=T      camera zoom_t 0..1 (0 = Z0, 0.5 = Z1, 1 = Z2). Default 0.
##   --reload      throw the live FloodView away, round-trip doc 07's weather
##                 section through JSON, build a NEW view and prime it from the
##                 deserialised flood field. The shot is then of a city that has
##                 consumed ZERO flood events — which is what a loaded save is.
##   --out=PATH    where the PNG lands
##   --shot-at=S   real seconds of warm-up before the shot (default 3.0)
##
## Render-side only. It forces weather, which the sim owns and doc 07 publishes
## a debug verb for; it never writes a depth, a band or a tile.

const RENDER_JSON := "res://data/render.json"

var _phase := "peak"
var _hours := -1.0
var _drain := -1.0
var _hour := -1.0
var _zoom := 0.0
var _out := ""
var _shot_at := 3.0
var _reload := false

var _main: Node
var _sim: CitySim
var _flood: FloodView
var _timer := 0.0
var _shot := false


func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--phase="):
			_phase = arg.trim_prefix("--phase=")
		elif arg.begins_with("--hours="):
			_hours = float(arg.trim_prefix("--hours="))
		elif arg.begins_with("--drain="):
			_drain = float(arg.trim_prefix("--drain="))
		elif arg.begins_with("--hour="):
			_hour = float(arg.trim_prefix("--hour="))
		elif arg.begins_with("--zoom="):
			_zoom = clampf(float(arg.trim_prefix("--zoom=")), 0.0, 1.0)
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--shot-at="):
			_shot_at = float(arg.trim_prefix("--shot-at="))
		elif arg == "--reload":
			_reload = true
	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	_arm()


func _arm() -> void:
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	if _sim == null:
		push_error("flood_preview: the shell did not come up")
		return
	var ui: UIRoot = _main.get("ui_root") as UIRoot
	if ui != null:
		# The tutorial owns the screen on a fresh boot and is not what this is
		# for. Same treatment `overlay_preview` gives it.
		ui.reset_onboarding()
		if ui.onboarding != null:
			ui.onboarding.visible = false

	# ══════════ the shell hook, verbatim ═══════════════════════════════════
	# These are the whole of the `game/main.gd` integration.
	var render_data: Dictionary = StarterCityLoader.read_json(RENDER_JSON)
	_flood = FloodView.new()
	_flood.name = "FloodView"
	_main.add_child(_flood)
	_flood.setup(render_data)
	_flood.rebuild(_sim.world.grid)
	_flood.prime(_sim.weather.flood.depth_mm)
	_flood.snap()
	host.ticked.connect(func(batch: Array) -> void: _flood.feed_events(batch))
	# ═══════════════════════════════════════════════════════════════════════

	_frame_on_a_low_block()
	# The clock is walled FIRST and the rain runs after it: winding nine hours
	# forward to reach 22:00 would otherwise drain everything the storm just
	# put down, which is exactly what it did the first time this was run.
	if _hour >= 0.0:
		var now := float(_sim.clock.minute_of_day()) / 60.0
		var ahead := _hour - now
		_sim.advance_hours(ahead if ahead > 0.0 else ahead + 24.0)
	_run_phase()
	if _reload:
		_reload_from_the_save_shape()
	_report()


## Doc 07's debug lever, and nothing else. THUNDERSTORM at intensity 1.0 is
## 35 mm/h (data/weather.json `states`), which on a LOW block's 6.0 runoff
## concentration is 210 mm/h in against a 40 mm/h drain — 170 mm/h net, so the
## 350 mm impassable band is a shade over two game-hours away. Those are doc
## 07 §2.4's numbers doing the work; this only starts the clock.
func _run_phase() -> void:
	var rain := 0.0
	var drain := 0.0
	match _phase:
		"rise":
			rain = 0.9
		"peak":
			rain = 2.6
		"recede":
			rain = 2.6
			drain = 3.2
		"dry":
			pass
		_:
			push_error("flood_preview: unknown --phase=" + _phase)
			return
	if _hours >= 0.0:
		rain = _hours
	if _drain >= 0.0:
		drain = _drain
	if rain > 0.0:
		_sim.weather.debug_force_weather("THUNDERSTORM", 1.0,
				int(ceilf(rain * 60.0 / 15.0)) * 15)
		_sim.advance_hours(rain)
	if drain > 0.0:
		_sim.weather.debug_force_weather("CLEAR", 0.0,
				int(ceilf(drain * 60.0 / 15.0)) * 15)
		_sim.advance_hours(drain)


## What a LOADED SAVE is, exactly: doc 07's weather section through the JSON it
## is stored as, a FloodView that has never seen an event, and `prime` off the
## deserialised field. If the flood is on screen after this, the claim in
## `flood_view.gd`'s header holds.
func _reload_from_the_save_shape() -> void:
	var blob := _sim.weather.serialize()
	var text := JSON.stringify(blob)
	var restored: Variant = JSON.parse_string(text)
	if not (restored is Dictionary):
		push_error("flood_preview: the weather section did not round-trip")
		return
	_sim.weather.deserialize(restored)
	_flood.queue_free()
	var render_data: Dictionary = StarterCityLoader.read_json(RENDER_JSON)
	_flood = FloodView.new()
	_flood.name = "FloodViewReloaded"
	_main.add_child(_flood)
	_flood.setup(render_data)
	_flood.rebuild(_sim.world.grid)
	_flood.prime(_sim.weather.flood.depth_mm)
	_flood.snap()
	print("flood_preview: reloaded from the save shape — %d cells, zero events"
			% _flood.cell_keys().size())


## Park on the LOW land block with the most road under it: the block that can
## flood and has a street to flood.
func _frame_on_a_low_block() -> void:
	var camera_state: CameraState = _main.get("camera_state") as CameraState
	if camera_state == null:
		return
	var best: LandBlock = null
	var best_roads := -1
	for block_id: String in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		if String(block.elevation_band()) != "LOW":
			continue
		var roads := 0
		for z in range(block.grid.y * 16, block.grid.y * 16 + 16):
			for x in range(block.grid.x * 16, block.grid.x * 16 + 16):
				if _sim.world.grid.has_flag(x, z, TileGrid.FLAG_ROAD):
					roads += 1
		if roads > best_roads:
			best_roads = roads
			best = block
	if best == null:
		return
	camera_state.set_focus(Vector3((best.grid.x * 16 + 8) * 8.0, 0.0,
			(best.grid.y * 16 + 8) * 8.0))
	camera_state.set_zoom_t(_zoom)
	print("flood_preview: framed %s (LOW, %d road tiles)" % [best.id, best_roads])


func _report() -> void:
	var deepest := 0.0
	for key: Variant in _sim.weather.flood.depth_mm:
		deepest = maxf(deepest, float(_sim.weather.flood.depth_mm[key]))
	print("flood_preview: phase=%s  cells wet=%d  deepest=%.1f mm  band=%s  closed=%d"
			% [_phase, _sim.weather.flood.depth_mm.size(), deepest,
			_sim.weather.flood.band_index(deepest),
			_sim.weather.flood.closed_tiles().size()])
	print("flood_preview: view cells=%d  drawn tiles=%d  draw calls=%d  detail=%d"
			% [_flood.cell_keys().size(), _flood.drawn_tiles(),
			_flood.draw_calls(), _flood.detail])


func _process(delta: float) -> void:
	if _flood == null:
		return
	_flood.refresh(delta)
	_timer += delta
	if _shot or _out == "" or _timer < _shot_at:
		return
	_shot = true
	print("flood_preview: shooting — drawn tiles=%d  draw calls=%d"
			% [_flood.drawn_tiles(), _flood.draw_calls()])
	var image := get_viewport().get_texture().get_image()
	image.save_png(_out)
	print("flood_preview: wrote " + _out)
	get_tree().quit()
