class_name EnvironmentController
extends Node
## Applies the DayNightController's sampled state to the WorldEnvironment,
## Sun and Moon each frame, and writes the global shader parameters
## (doc 11 §2.4/§2.8). Pure application — all arithmetic lives in
## DayNightController where it is headless-tested.
##
## Weather (doc 11 §2.9) folds in HERE rather than in `WeatherFX`, on purpose:
## every write to the WorldEnvironment, the sun and the sky belongs to one
## file, or the day/night gradient and the storm end up fighting over the same
## properties from two places. `WeatherFX` hands over three scalars —
## a fog profile with its crossfade, a storm darkness, and the lightning `f` —
## and the day/night sample stays the base every one of them modifies.

@export var world_environment_path: NodePath
@export var sun_path: NodePath
@export var moon_path: NodePath

var controller := DayNightController.new()
var far_cull_m: float = 1200.0
var render_clock_s: float = 0.0
## Last sampled night scalar (0 day .. 1 night) for views that need it on CPU.
var last_night: float = 0.0

## Weather coupling (§2.9). `weather_profile` names one of §2.8's four fog
## profiles; `weather_mix` and `storm` are crossfaded toward their targets at
## the authored `fog_crossfade_s` rate so a segment boundary is a weather
## CHANGE, not a weather CUT.
var weather_profile: String = ""
var weather_mix_target: float = 0.0
var storm_target: float = 0.0
var weather_mix: float = 0.0
var storm: float = 0.0
## `f` from §2.9: the lightning envelope × the strike magnitude. Written by
## WeatherFX every frame; zero the rest of the time.
var flash: float = 0.0

var _environment: Environment
var _sky_material: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _sky_energy_base: float = 1.0
var _lightning_color := Color(0.788, 0.839, 1.0)      # #C9D6FF
var _lightning_fog_color := Color(0.682, 0.745, 0.878)  # #AEBEE0
var _lightning_sky_gain: float = 6.0
var _lightning_ambient_gain: float = 4.0
var _lightning_dir_energy: float = 2.4
var _lightning_fog_blend: float = 0.7
## Storm darkening constants. The storm slate is blended in OKLAB against the
## sampled sky, not multiplied in sRGB: a straight `darkened()` on the 18:30
## horizon turns it muddy brown, which is the exact failure §2.8 chose Oklab to
## avoid in the first place.
const STORM_SLATE := Color(0.36, 0.40, 0.46)
const STORM_SKY_BLEND := 0.70
const STORM_SUN_CUT := 0.70
const STORM_AMBIENT_CUT := 0.45
const STORM_SATURATION_CUT := 0.18
const STORM_SHADOW_OFF := 0.60
const FLASH_DAY_SCALE := 0.22


func setup(render_data: Dictionary) -> void:
	if not controller.load_from(render_data):
		push_error("day/night data invalid: " + ", ".join(controller.errors))
	var presets: Dictionary = render_data.get("presets", {})
	far_cull_m = float(presets.get("balanced", {}).get("far_cull_m", 1200.0))
	_environment = (get_node(world_environment_path) as WorldEnvironment).environment
	_sky_material = _environment.sky.sky_material as ProceduralSkyMaterial
	_sky_energy_base = _sky_material.energy_multiplier
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
	var weather: Dictionary = render_data.get("weather", {})
	_lightning_color = Color(String(weather.get("lightning_color", "#C9D6FF")))
	_lightning_fog_color = Color(String(weather.get("lightning_fog_color", "#AEBEE0")))
	_lightning_sky_gain = float(weather.get("lightning_sky_gain", 6.0))
	_lightning_ambient_gain = float(weather.get("lightning_ambient_gain", 4.0))
	_lightning_dir_energy = float(weather.get("lightning_dir_energy", 2.4))
	_lightning_fog_blend = float(weather.get("lightning_fog_blend", 0.7))


## Doc 11 §2.9's renderer-side weather state. `profile` is "" for clear skies,
## otherwise one of §2.8's weather fog profiles ("rain", "fog_weather").
func set_weather(profile: String, mix: float, p_storm: float) -> void:
	weather_profile = profile
	weather_mix_target = clampf(mix, 0.0, 1.0)
	storm_target = clampf(p_storm, 0.0, 1.0)


## `f` from §2.9. Scaled DOWN in daylight: the authored gains (sky ×7, ambient
## ×5) are calibrated against a night frame, and applied to a noon sky they
## blow the background to white — which is both wrong (a daytime stroke barely
## registers against the sun) and the exact photosensitivity spike §2.9 refuses.
## The scale is by `sc_night`, so dusk gets a partial flash and midnight the
## full one.
func set_flash(f: float) -> void:
	flash = clampf(f, 0.0, 1.0) * lerpf(FLASH_DAY_SCALE, 1.0, last_night)


func apply(hour: float, delta: float) -> void:
	if _environment == null:
		return
	render_clock_s = fmod(render_clock_s + delta, 3600.0)
	_advance_weather(delta)
	var s := controller.sample(hour)
	# ---------------------------------------------------------------- sky
	var sky_top := _storm_shift(s["sky_top"])
	var sky_horizon := _storm_shift(s["sky_horizon"])
	_sky_material.sky_top_color = sky_top
	_sky_material.sky_horizon_color = sky_horizon
	# Ground hemisphere must meet the sky at the SAME horizon color or the
	# seam reads as a dark band across the skyline from any elevated camera.
	_sky_material.ground_horizon_color = sky_horizon
	_sky_material.ground_bottom_color = sky_horizon.darkened(0.55)
	# §2.9's sky pop: the stroke lights the CLOUD DECK, so the sky brightens
	# and the façades catch it a frame later through ambient + sun.
	_sky_material.energy_multiplier = _sky_energy_base * (1.0 + _lightning_sky_gain * flash)
	# ---------------------------------------------------------------- sun
	var elevation: float = s["sun_elevation_deg"]
	var azimuth: float = s["sun_azimuth_deg"]
	_sun.rotation_degrees = Vector3(-maxf(elevation, 1.0), azimuth, 0.0)
	_sun.light_energy = float(s["sun_energy"]) * (1.0 - STORM_SUN_CUT * storm) \
			+ _lightning_dir_energy * flash
	_sun.light_color = (s["sun_color"] as Color).lerp(_lightning_color, flash)
	# An overcast storm has no crisp shadow to cast; dropping the pass is both
	# the honest look and the cheapest frame of the whole weather system.
	_sun.shadow_enabled = elevation > 2.0 and storm < STORM_SHADOW_OFF
	if _moon != null:
		_moon.light_energy = controller.moon_energy * float(s["night"]) \
				* (1.0 - storm)
		_moon.light_color = controller.moon_color
		_moon.rotation_degrees = Vector3(-50.0, azimuth + 180.0, 0.0)
	# ------------------------------------------------------------ ambient
	_environment.ambient_light_energy = float(s["ambient_energy"]) \
			* (1.0 - STORM_AMBIENT_CUT * storm) * (1.0 + _lightning_ambient_gain * flash)
	_environment.adjustment_saturation = float(s["saturation"]) \
			* (1.0 - STORM_SATURATION_CUT * storm)
	# ---------------------------------------------------------------- fog
	var fog: Dictionary = controller.fog_state(float(s["night"]), far_cull_m,
			weather_profile, weather_mix)
	var fog_tint := _storm_shift(s["fog_tint"])
	_environment.fog_light_color = fog_tint.lerp(_lightning_fog_color,
			_lightning_fog_blend * flash)
	_environment.fog_density = float(fog.get("density", 0.0012))
	_environment.fog_sky_affect = float(fog.get("sky", 0.5))
	_environment.fog_aerial_perspective = float(fog.get("aerial", 0.3))
	last_night = float(s["night"])
	RenderingServer.global_shader_parameter_set("sc_night", last_night)
	RenderingServer.global_shader_parameter_set("sc_time", render_clock_s)
	RenderingServer.global_shader_parameter_set("sc_fog_tint",
			Vector3(fog_tint.r, fog_tint.g, fog_tint.b))


## Both weather scalars crossfade at §2.8's authored rate (4 s for a full
## swing), so a segment boundary in doc 07 never cuts the sky.
func _advance_weather(delta: float) -> void:
	var rate := delta / maxf(0.05, controller.fog_crossfade_s)
	weather_mix = move_toward(weather_mix, weather_mix_target, rate)
	storm = move_toward(storm, storm_target, rate)


## Blend a sampled day/night colour toward the storm slate in Oklab, keeping
## §2.8's hue path. At storm = 0 this returns the sample untouched.
func _storm_shift(base: Variant) -> Color:
	var color: Color = base
	if storm <= 0.0:
		return color
	var slate := DayNightController.oklab_lerp(color, STORM_SLATE, STORM_SKY_BLEND)
	slate = slate.darkened(0.30 * storm)
	return DayNightController.oklab_lerp(color, slate, storm)
