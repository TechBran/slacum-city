class_name WeatherFX
extends Node3D
## Weather VFX (doc 11 §2.9): rain, splashes, the wetness integrator and the
## lightning flash — everything the player actually SEES of doc 07.
##
## Three rules this file exists to hold:
##
## 1. **`precip01` is the only precipitation input** (report C-58, ruled). Doc
##    07 publishes it continuous on [0,1] and crossfaded across segment
##    boundaries; this node never sees `precip_mm_h`, the weather enum's
##    intensity table, or any per-state curve. The enum arrives only to pick a
##    fog profile and to know that a THUNDERSTORM sky is darker than the same
##    rain rate under an overcast one.
##
## 2. **Nothing restarts.** Intensity rides `amount_ratio`, so rain thickens
##    and thins continuously; a `restart()` would dump the whole bed and pop.
##
## 3. **The lightning flash is lighting, not a white quad.** `sc_lightning`
##    follows §2.9's two-stroke envelope and EnvironmentController turns it
##    into five property writes on the sky, sun, ambient and fog. A fullscreen
##    flash would light nothing, read as a bug on an OLED panel, and is a
##    photosensitivity hazard the doc explicitly refuses.
##
## The node is render-only and reads no sim state directly: it is fed the two
## doc-07 events and the camera focus, and it writes the four project shader
## globals the building, ground, lamp and pool shaders consume.

## Doc 11 §2.9's two-stroke envelope, seconds after the strike.
const LIGHTNING_ENVELOPE_FALLBACK: Array = [
	[0.0, 0.0], [0.02, 1.0], [0.09, 0.15], [0.13, 0.85], [0.30, 0.0],
]

## Weather states whose fog profile is `rain` (doc 11 §2.8's four profiles).
const WET_STATES := ["RAIN", "HEAVY_RAIN", "THUNDERSTORM"]

var environment_controller: EnvironmentController

## Published render state — read by tests and by the HUD if it ever wants it.
var precip01: float = 0.0
var wetness: float = 0.0
var wind_ms: Vector2 = Vector2.ZERO
var weather_state: String = "CLEAR"
var intensity: float = 0.0
## `sc_lightning`: the bare envelope, 0..1. `flash01()` is that × magnitude,
## which is the `f` doc 11 §2.9 writes the five light properties from.
var lightning01: float = 0.0
## Accessibility (doc 11 §2.9 / doc 12): scales the envelope, never its shape.
var reduce_flashes: bool = false
## Dev/visual-review only: hold a weather state and ignore doc 07's stream, so
## a screenshot of a storm does not depend on the sim happening to be in one.
## Never set in normal play — the renderer follows the simulation.
var pinned: bool = false

var _rain: GPUParticles3D
var _splash: GPUParticles3D
var _rain_process: ParticleProcessMaterial
var _splash_process: ParticleProcessMaterial
var _cfg: Dictionary = {}
var _presets: Dictionary = {}
var _preset := "balanced"
var _splash_enabled := true
var _envelope: Array = LIGHTNING_ENVELOPE_FALLBACK
var _flash_t: float = -1.0
var _flash_magnitude: float = 0.0
var _rain_box := Vector3(90.0, 40.0, 90.0)
var _rain_box_y := 20.0
var _splash_radius := 60.0
var _wind_gain := 2.2
var _gravity_y := -22.0
var _tau_up := 25.0
var _tau_down := 90.0
var _wetness_gain := 1.2
var _reduce_scale := 0.25


# ---------------------------------------------------------------------- boot

func setup(render_data: Dictionary, env: EnvironmentController = null,
		preset := "balanced") -> void:
	environment_controller = env
	# The node itself never moves, so a child's `position` IS world space — and
	# `position` works outside the scene tree, which `global_position` does not.
	# That is what lets the whole integrator be exercised headless.
	transform = Transform3D.IDENTITY
	_cfg = render_data.get("weather", {})
	_presets = render_data.get("presets", {})
	_preset = preset
	var box: Array = _cfg.get("rain_box_m", [90.0, 40.0, 90.0])
	_rain_box = Vector3(float(box[0]), float(box[1]), float(box[2]))
	_rain_box_y = float(_cfg.get("rain_box_y_offset_m", 20.0))
	_splash_radius = float(_cfg.get("splash_radius_m", 60.0))
	_wind_gain = float(_cfg.get("rain_wind_gain", 2.2))
	_gravity_y = float(_cfg.get("rain_gravity_y", -22.0))
	_tau_up = float(_cfg.get("wetness_tau_up_s", 25.0))
	_tau_down = float(_cfg.get("wetness_tau_down_s", 90.0))
	_wetness_gain = float(_cfg.get("wetness_precip_gain", 1.2))
	_reduce_scale = float(_cfg.get("lightning_reduce_flashes_scale", 0.25))
	var envelope: Array = _cfg.get("lightning_envelope", [])
	if envelope.size() >= 2:
		_envelope = envelope
	_build_rain()
	_build_splash()
	set_preset(preset)
	_publish_globals()


## Preset switch (doc 11 §2.13): particle COUNTS change, `amount_ratio` does
## not. Changing `amount` restarts the bed, so this is a settings-time call.
func set_preset(name: String) -> void:
	_preset = name
	var preset: Dictionary = _presets.get(name, _presets.get("balanced", {}))
	var rain_count := int(preset.get("rain", 4000))
	var splash_count := int(preset.get("splash", 600))
	if _rain != null and _rain.amount != rain_count:
		_rain.amount = maxi(1, rain_count)
	_splash_enabled = splash_count > 0     # Performance ships splash = 0
	if _splash != null:
		_splash.visible = false
		if _splash_enabled and _splash.amount != splash_count:
			_splash.amount = splash_count


func _build_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	_rain.local_coords = false        # §2.9: drops must not swim during a pan
	_rain.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Y_TO_VELOCITY
	_rain.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_rain.amount_ratio = 0.0
	_rain.emitting = false
	_rain.visible = false
	# Fall time through the box: v² = 2·g·h from the top of the box to the pad.
	var drop_m := _rain_box.y + _rain_box_y
	_rain.lifetime = sqrt(2.0 * drop_m / maxf(1.0, absf(_gravity_y)))
	_rain.preprocess = _rain.lifetime   # a full bed on the first visible frame
	_rain.visibility_aabb = AABB(
			Vector3(-_rain_box.x, -_rain_box_y - 4.0, -_rain_box.z),
			Vector3(_rain_box.x * 2.0, _rain_box.y + _rain_box_y + 8.0, _rain_box.z * 2.0))
	_rain_process = ParticleProcessMaterial.new()
	_rain_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_process.emission_box_extents = Vector3(
			_rain_box.x * 0.5, _rain_box.y * 0.5, _rain_box.z * 0.5)
	_rain_process.direction = Vector3(0.0, -1.0, 0.0)
	_rain_process.spread = 0.0
	_rain_process.initial_velocity_min = 2.0
	_rain_process.initial_velocity_max = 4.0
	_rain_process.gravity = Vector3(0.0, _gravity_y, 0.0)
	_rain_process.scale_min = 0.85
	_rain_process.scale_max = 1.35
	_rain.process_material = _rain_process
	var quad: Array = _cfg.get("rain_quad_m", [0.02, 0.55])
	var mesh := QuadMesh.new()
	mesh.size = Vector2(float(quad[0]), float(quad[1]))
	# The quad's own origin is its centre; Y_TO_VELOCITY spins it onto the fall
	# direction, so the streak trails the drop.
	_rain.draw_pass_1 = mesh
	_rain.material_override = _drop_material()
	add_child(_rain)


func _build_splash() -> void:
	_splash = GPUParticles3D.new()
	_splash.name = "Splash"
	_splash.local_coords = false
	_splash.amount_ratio = 0.0
	_splash.emitting = false
	_splash.visible = false
	_splash.lifetime = float(_cfg.get("splash_lifetime_s", 0.28))
	_splash.visibility_aabb = AABB(
			Vector3(-_splash_radius, -2.0, -_splash_radius),
			Vector3(_splash_radius * 2.0, 6.0, _splash_radius * 2.0))
	_splash_process = ParticleProcessMaterial.new()
	_splash_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	_splash_process.emission_ring_axis = Vector3(0.0, 1.0, 0.0)
	_splash_process.emission_ring_radius = _splash_radius
	_splash_process.emission_ring_inner_radius = 0.0
	_splash_process.emission_ring_height = 0.02
	_splash_process.direction = Vector3(0.0, 1.0, 0.0)
	_splash_process.spread = 15.0
	_splash_process.initial_velocity_min = 0.4
	_splash_process.initial_velocity_max = 1.1
	_splash_process.gravity = Vector3(0.0, -9.0, 0.0)
	_splash_process.scale_min = 0.6
	_splash_process.scale_max = 1.4
	_splash.process_material = _splash_process
	var quad: Array = _cfg.get("splash_quad_m", [0.35, 0.35])
	var mesh := PlaneMesh.new()   # XZ-oriented: a splash lies on the road
	mesh.size = Vector2(float(quad[0]), float(quad[1]))
	_splash.draw_pass_1 = mesh
	_splash.material_override = _splash_material()
	add_child(_splash)


# ------------------------------------------------------------------ materials
#
# Both particle materials are written here rather than as `.gdshader` files:
# they are ten lines each, they exist only for this node, and keeping them next
# to the emitter that configures them is what stops the quad size, the draw
# alignment and the shader's assumptions about UV from drifting apart.

## Rain drop: unshaded additive streak, brightened by `sc_lightning` (§2.9).
##
## The width clamp is the one deviation worth reading. Doc 11 authors the quad
## at a true-to-life `0.02 × 0.55` m, and at the camera's own D_MAX of 420 m
## that is 0.03 of a pixel — the rasteriser drops it and the storm is invisible
## on exactly the shot that most needs it. So the authored metre size is the
## BASE and the vertex stage widens the streak only as far as it must to stay
## about a pixel and a half across. At close zoom the clamp is inactive and the
## drop is the authored size.
func _drop_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled;

global uniform float sc_lightning;
global uniform float sc_night;

uniform vec3 drop_color: source_color = vec3(0.72, 0.80, 0.94);
uniform float drop_energy = 0.8;
uniform float min_width_px = 1.6;
uniform float min_length_px = 9.0;

void vertex() {
	// View-space depth of the drop's centre, then how many pixels one metre at
	// that depth covers on each screen axis.
	float z = -(MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).z;
	float px_x = PROJECTION_MATRIX[0][0] * 0.5 * VIEWPORT_SIZE.x / max(z, 0.05);
	float px_y = PROJECTION_MATRIX[1][1] * 0.5 * VIEWPORT_SIZE.y / max(z, 0.05);
	float half_w = max(abs(VERTEX.x), 1e-5) * px_x;
	float half_l = max(abs(VERTEX.y), 1e-5) * px_y;
	VERTEX.x *= max(1.0, (min_width_px * 0.5) / half_w);
	VERTEX.y *= max(1.0, (min_length_px * 0.5) / half_l);
}

void fragment() {
	// Soft along the streak, hard across it: a drop is a line, not a blob.
	float along = 1.0 - abs(UV.y - 0.5) * 2.0;
	float across = 1.0 - abs(UV.x - 0.5) * 2.0;
	float shape = pow(clamp(along, 0.0, 1.0), 0.6) * clamp(across, 0.0, 1.0);
	// Rain is lit by the sky: dimmer at night, and every drop in frame lights
	// up on the stroke. That flash-lit sheet is the whole read of a storm.
	float lit = mix(1.0, 0.55, sc_night) + 2.2 * sc_lightning;
	ALBEDO = drop_color * shape * drop_energy * lit;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


## Splash: a flat additive ring on the ground, fading over its own lifetime.
func _splash_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled;

global uniform float sc_night;

uniform vec3 splash_color: source_color = vec3(0.78, 0.85, 0.96);
uniform float splash_energy = 0.5;

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	// A ring, not a disc: the crown of a drop hitting a wet road.
	float ring = smoothstep(0.35, 0.75, d) * (1.0 - smoothstep(0.75, 1.0, d));
	ALBEDO = splash_color * ring * splash_energy * mix(1.0, 0.6, sc_night);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


# --------------------------------------------------------------------- events

## Feed a drained sim batch. Returns true if anything weather-shaped was in it.
func feed_events(batch: Array) -> bool:
	var touched := false
	for event: Variant in batch:
		if typeof(event) == TYPE_DICTIONARY and apply_event(event):
			touched = true
	return touched


func apply_event(e: Dictionary) -> bool:
	match StringName(String(e.get("type", &""))):
		&"weather_changed":
			if pinned:
				return true
			set_weather(String(e.get("weather_state", e.get("weather_type", "CLEAR"))),
					float(e.get("precip01", 0.0)), float(e.get("intensity", 0.0)),
					e.get("wind", Vector2.ZERO))
			return true
		&"lightning_strike":
			strike(float(e.get("magnitude", 0.6)))
			return true
		&"lightning_flash_cosmetic":
			# Doc 07's in-cloud flashes: no strike, no damage, same sky.
			strike(float(e.get("magnitude", 0.4)))
			return true
		_:
			return false


## The doc-11 §5 renderer contract, unpacked. `wind` is doc 07's metres/second
## vector; the rain bed tilts with it and doc 13's wind bed follows its length.
func set_weather(state: String, p_precip01: float, p_intensity: float,
		wind: Variant = Vector2.ZERO) -> void:
	weather_state = state
	precip01 = clampf(p_precip01, 0.0, 1.0)
	intensity = clampf(p_intensity, 0.0, 1.0)
	if wind is Vector2:
		wind_ms = wind
	elif wind is Vector3:
		wind_ms = Vector2((wind as Vector3).x, (wind as Vector3).z)


## Dev arg helper: set the weather AND stop listening to doc 07 for the rest of
## the session (see `pinned`).
func pin_weather(state: String, p_precip01: float, p_intensity: float,
		wind: Variant = Vector2.ZERO) -> void:
	set_weather(state, p_precip01, p_intensity, wind)
	pinned = true


## Start (or restart) the §2.9 flash envelope. A second strike inside 0.30 s
## re-triggers rather than stacking — two overlapping envelopes would blow past
## the luminance clamp, which is the one thing this effect must never do.
func strike(magnitude: float) -> void:
	_flash_t = 0.0
	_flash_magnitude = clampf(magnitude, 0.0, 1.0)


## `f` in §2.9's five light writes: the envelope scaled by the strike energy.
func flash01() -> float:
	return lightning01 * _flash_magnitude


# -------------------------------------------------------------------- per frame

## `focus` is the camera's ground focus (doc 12 owns it). Everything follows it
## so the emitters stay a local box around what the player is looking at rather
## than a city-sized volume.
func refresh(delta: float, focus: Vector3) -> void:
	_advance_wetness(delta)
	_advance_flash(delta)
	# Dry weather draws nothing. `emitting = false` alone is not enough: the
	# node still submits its (empty, or preprocessed-and-expiring) buffer, and
	# a clear midnight came out speckled with leftover drops. Hiding the
	# emitter is both the correct picture and one fewer draw call for the ~95%
	# of play time that is not a storm.
	var raining := precip01 > 0.001
	if _rain != null:
		_rain.visible = raining
		_rain.emitting = raining
		_rain.position = focus + Vector3(0.0, _rain_box_y, 0.0)
		_rain.amount_ratio = precip01
		_rain_process.gravity = Vector3(
				wind_ms.x * _wind_gain, _gravity_y, wind_ms.y * _wind_gain)
	if _splash != null and _splash_enabled:
		# §2.9: splashes appear LATE — squared, so they read as "getting serious".
		var splashing := precip01 > 0.05
		_splash.visible = splashing
		_splash.emitting = splashing
		_splash.position = Vector3(focus.x, 0.06, focus.z)
		_splash.amount_ratio = precip01 * precip01
	_publish_globals()
	_push_environment()


## §2.9's integrator: soaks fast (τ 25 s), dries slow (τ 90 s). `precip01 ≥
## 0.834` saturates the target, i.e. anything past ≈29 mm/h is "fully soaked".
func _advance_wetness(delta: float) -> void:
	var target := clampf(precip01 * _wetness_gain, 0.0, 1.0)
	var tau := _tau_up if target > wetness else _tau_down
	wetness += (target - wetness) * (1.0 - exp(-delta / maxf(0.001, tau)))
	wetness = clampf(wetness, 0.0, 1.0)


func _advance_flash(delta: float) -> void:
	if _flash_t < 0.0:
		lightning01 = 0.0
		return
	_flash_t += delta
	lightning01 = _sample_envelope(_flash_t)
	if reduce_flashes:
		lightning01 *= _reduce_scale
	if _flash_t > float((_envelope[_envelope.size() - 1] as Array)[0]):
		_flash_t = -1.0
		lightning01 = 0.0


func _sample_envelope(t: float) -> float:
	var previous: Array = _envelope[0]
	for i in _envelope.size():
		var key: Array = _envelope[i]
		if float(key[0]) >= t:
			var span := float(key[0]) - float(previous[0])
			if span <= 0.0:
				return float(key[1])
			var u := (t - float(previous[0])) / span
			return lerpf(float(previous[1]), float(key[1]), u)
		previous = key
	return 0.0


func _publish_globals() -> void:
	RenderingServer.global_shader_parameter_set("sc_wetness", wetness)
	RenderingServer.global_shader_parameter_set("sc_lightning", lightning01)
	RenderingServer.global_shader_parameter_set("sc_wind", wind_ms)


## The sky, sun, ambient and fog belong to EnvironmentController — this node
## hands it the two weather scalars and the flash, and never touches an
## Environment property itself. Keeping every write to the WorldEnvironment in
## one file is what stops the day/night gradient and the storm from fighting.
func _push_environment() -> void:
	if environment_controller == null:
		return
	environment_controller.set_weather(fog_profile(), fog_mix(), storm01())
	environment_controller.set_flash(flash01())


## Which of doc 11 §2.8's four fog profiles this weather crossfades toward.
func fog_profile() -> String:
	return "rain" if WET_STATES.has(weather_state) else ""


## How far toward it. Rain thickens the air well before it soaks the ground, so
## this follows precip01 directly rather than the wetness integrator.
func fog_mix() -> float:
	return clampf(precip01 * 1.15, 0.0, 1.0)


## Sky/sun darkening, 0..1. A thunderstorm at a given rain rate is darker than
## plain rain at the same rate — that difference is the whole reason the enum
## still reaches the renderer at all (§2.9 otherwise consumes precip01 only).
func storm01() -> float:
	var base := clampf(precip01 * 1.1, 0.0, 1.0)
	if weather_state == "THUNDERSTORM":
		base = clampf(base + 0.25 * maxf(intensity, 0.4), 0.0, 1.0)
	elif weather_state == "CLOUDY":
		base = maxf(base, 0.22 * intensity)
	return base
