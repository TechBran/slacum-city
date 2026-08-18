class_name EnvironmentController
extends Node
## Applies the DayNightController's sampled state to the WorldEnvironment,
## Sun and Moon each frame, and writes the global shader parameters
## (doc 11 §2.4/§2.8). Pure application — all arithmetic lives in
## DayNightController where it is headless-tested.

@export var world_environment_path: NodePath
@export var sun_path: NodePath
@export var moon_path: NodePath

var controller := DayNightController.new()
var far_cull_m: float = 1200.0
var render_clock_s: float = 0.0
var _environment: Environment
var _sky_material: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D


func setup(render_data: Dictionary) -> void:
	if not controller.load_from(render_data):
		push_error("day/night data invalid: " + ", ".join(controller.errors))
	var presets: Dictionary = render_data.get("presets", {})
	far_cull_m = float(presets.get("balanced", {}).get("far_cull_m", 1200.0))
	_environment = (get_node(world_environment_path) as WorldEnvironment).environment
	_sky_material = _environment.sky.sky_material as ProceduralSkyMaterial
	_sun = get_node(sun_path) as DirectionalLight3D
	if moon_path != NodePath("") and has_node(moon_path):
		_moon = get_node(moon_path) as DirectionalLight3D
	var environment_data: Dictionary = render_data.get("environment", {})
	_environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	_environment.tonemap_exposure = float(environment_data.get("tonemap_exposure", 1.0))
	_environment.tonemap_white = float(environment_data.get("tonemap_white", 6.0))
	_environment.adjustment_enabled = true
	_environment.adjustment_contrast = float(environment_data.get("contrast", 1.06))
	var glow: Dictionary = presets.get("balanced", {})
	_environment.glow_enabled = true
	_environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	_environment.glow_intensity = float(glow.get("glow_intensity", 0.9))
	_environment.glow_strength = float(glow.get("glow_strength", 1.0))
	_environment.glow_bloom = float(glow.get("glow_bloom", 0.05))
	_environment.fog_enabled = true


func apply(hour: float, delta: float) -> void:
	if _environment == null:
		return
	render_clock_s = fmod(render_clock_s + delta, 3600.0)
	var s := controller.sample(hour)
	_sky_material.sky_top_color = s["sky_top"]
	_sky_material.sky_horizon_color = s["sky_horizon"]
	# Ground hemisphere must meet the sky at the SAME horizon color or the
	# seam reads as a dark band across the skyline from any elevated camera.
	_sky_material.ground_horizon_color = s["sky_horizon"]
	_sky_material.ground_bottom_color = (s["sky_horizon"] as Color).darkened(0.55)
	var elevation: float = s["sun_elevation_deg"]
	var azimuth: float = s["sun_azimuth_deg"]
	_sun.rotation_degrees = Vector3(-maxf(elevation, 1.0), azimuth, 0.0)
	_sun.light_energy = s["sun_energy"]
	_sun.light_color = s["sun_color"]
	_sun.shadow_enabled = elevation > 2.0
	if _moon != null:
		_moon.light_energy = controller.moon_energy * float(s["night"])
		_moon.light_color = controller.moon_color
		_moon.rotation_degrees = Vector3(-50.0, azimuth + 180.0, 0.0)
	_environment.ambient_light_energy = s["ambient_energy"]
	_environment.adjustment_saturation = s["saturation"]
	var fog: Dictionary = controller.fog_state(float(s["night"]), far_cull_m)
	_environment.fog_light_color = s["fog_tint"]
	_environment.fog_density = float(fog.get("density", 0.0012))
	_environment.fog_sky_affect = float(fog.get("sky", 0.5))
	_environment.fog_aerial_perspective = float(fog.get("aerial", 0.3))
	RenderingServer.global_shader_parameter_set("sc_night", float(s["night"]))
	RenderingServer.global_shader_parameter_set("sc_time", render_clock_s)
	RenderingServer.global_shader_parameter_set("sc_fog_tint",
			Vector3((s["fog_tint"] as Color).r, (s["fog_tint"] as Color).g, (s["fog_tint"] as Color).b))
