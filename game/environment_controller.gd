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

## §2.13b's preset state, written by `apply_quality()` and read per frame.
## They are held rather than applied once because each composes with a
## per-frame value: the shadow gate with sun elevation and storm cover, the
## glow threshold with the night scalar.
var _shadows_allowed := true
var _glow_hdr_day: float = 1.05
var _glow_hdr_night: float = 0.78
var _env_adjustments := true
var _contrast: float = 1.06

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
	_contrast = float(environment_data.get("contrast", 1.06))
	_environment.adjustment_contrast = _contrast
	# Glow is ON unconditionally — it is on §2.13's protected list and the
	# blackout relight is the game's signature moment. WHICH glow is the
	# preset's business, and it arrives through `apply_quality()`. Until it
	# does, the Balanced row is the fallback (`QualityApplier.resolve` with no
	# preset resolves to `balanced` for exactly the same reason), so a caller
	# that never applies a quality block gets what shipped before §2.13b.
	_environment.glow_enabled = true
	apply_quality(QualityApplier.resolve(render_data, "balanced"))
	_environment.fog_enabled = true
	var weather: Dictionary = render_data.get("weather", {})
	_lightning_color = Color(String(weather.get("lightning_color", "#C9D6FF")))
	_lightning_fog_color = Color(String(weather.get("lightning_fog_color", "#AEBEE0")))
	_lightning_sky_gain = float(weather.get("lightning_sky_gain", 6.0))
	_lightning_ambient_gain = float(weather.get("lightning_ambient_gain", 4.0))
	_lightning_dir_energy = float(weather.get("lightning_dir_energy", 2.4))
	_lightning_fog_blend = float(weather.get("lightning_fog_blend", 0.7))


## Doc 11 §2.13b — the ENVIRONMENT half of a graphics preset, from
## `QualityApplier.resolve()`. Called at boot, when the player picks a preset,
## and on the governor's latched drop; safe to call every one of those, because
## every write here is idempotent.
##
## THE TWO KEYS THAT ARE NOT WRITTEN HERE and why. `glow_hdr_threshold` is
## day/night dependent (§2.4 lifts the threshold in daylight so a lit window
## does not bloom at noon), so its two ends are STORED and the lerp happens in
## `apply()` against the same `night` scalar everything else uses. `shadows`
## is stored for the same reason: `apply()` re-derives `_sun.shadow_enabled`
## every frame from sun elevation and storm cover, so the preset gate has to
## be ANDed there or the next frame overwrites it (report 98 RR-98).
func apply_quality(resolved: Dictionary) -> void:
	if _environment == null:
		return
	far_cull_m = float(resolved.get("far_cull_m", far_cull_m))
	_shadows_allowed = bool(resolved.get("shadows_allowed", true))
	_glow_hdr_day = float(resolved.get("glow_hdr_threshold_day", 1.05))
	_glow_hdr_night = float(resolved.get("glow_hdr_threshold_night", 0.78))
	_environment.glow_blend_mode = \
			int(resolved.get("glow_blend", 1)) as Environment.GlowBlendMode
	_environment.glow_intensity = float(resolved.get("glow_intensity", 0.9))
	_environment.glow_strength = float(resolved.get("glow_strength", 1.0))
	_environment.glow_bloom = float(resolved.get("glow_bloom", 0.05))
	_environment.glow_hdr_scale = float(resolved.get("glow_hdr_scale", 2.0))
	var levels: Array = resolved.get("glow_levels", [])
	for i in range(mini(levels.size(), QualityApplier.GLOW_LEVEL_COUNT)):
		_environment.set_glow_level(i, float(levels[i]))
	# §2.8's tonemap curve is not a preset axis — it is the game's LOOK, and a
	# phone that turns it off is playing a different game. Only the colour
	# correction pass (contrast + the per-hour saturation ramp) is optional,
	# and Performance is the row that authors it off: `adjustment_enabled` is
	# a full-screen pass on a fragment-bound device.
	_env_adjustments = bool(resolved.get("env_adjustments", true))
	_environment.adjustment_enabled = _env_adjustments
	_environment.adjustment_contrast = _contrast if _env_adjustments else 1.0
	if _sun != null:
		_sun.directional_shadow_mode = \
				int(resolved.get("shadow_mode", 1)) as DirectionalLight3D.ShadowMode
		_sun.directional_shadow_max_distance = \
				float(resolved.get("shadow_max_m", 150.0))
	if _moon != null:
		# RR-83: a node that draws nothing is hidden, not dimmed. A moon at
		# energy 0 is still a shadow-casting directional light in the pass.
		_moon.visible = bool(resolved.get("moon", true))


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
	# §2.13b: the preset's gate AND the frame's. Performance authors
	# `shadows: false` and its sun never casts, whatever the hour.
	_sun.shadow_enabled = _shadows_allowed and elevation > 2.0 \
			and storm < STORM_SHADOW_OFF
	if _moon != null:
		_moon.light_energy = controller.moon_energy * float(s["night"]) \
				* (1.0 - storm)
		_moon.light_color = controller.moon_color
		_moon.rotation_degrees = Vector3(-50.0, azimuth + 180.0, 0.0)
	# ------------------------------------------------------------ ambient
	# §2.8's deep-night ambient FLOOR. `ambient_light_color` is dead weight
	# while `sky_contribution` is 1.0 (the sky IS the ambient), so the two are
	# written together: as the contribution falls the authored moonlight colour
	# fades in and gives the unlit geometry a blue-grey base the near-black
	# night sky cannot supply. A storm keeps the floor — an overcast night is
	# BRIGHTER at ground level, not darker — but the sky-driven half is cut.
	_environment.ambient_light_color = s["ambient_color"]
	_environment.ambient_light_sky_contribution = float(s["ambient_sky_contribution"])
	var sky_cut := 1.0 - STORM_AMBIENT_CUT * storm * float(s["ambient_sky_contribution"])
	_environment.ambient_light_energy = float(s["ambient_energy"]) \
			* sky_cut * (1.0 + _lightning_ambient_gain * flash)
	_environment.adjustment_saturation = float(s["saturation"]) \
			* (1.0 - STORM_SATURATION_CUT * storm)
	# §2.13b's glow threshold, day to night. A lit window is ~2.4 nits against
	# a noon sky the tonemapper puts near 1.0, so a night threshold applied at
	# midday blooms the whole façade; the preset authors both ends and the
	# night scalar picks the point between them.
	_environment.glow_hdr_threshold = lerpf(_glow_hdr_day, _glow_hdr_night,
			float(s["night"]))
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
