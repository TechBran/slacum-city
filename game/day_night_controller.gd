class_name DayNightController
extends RefCounted
## Day/night gradient sampling (doc 11 §2.8). RefCounted so the whole
## gradient — including the Oklab hue interpolation — is headless-testable;
## EnvironmentController is the thin Node that applies the sampled state.
##
## Colors interpolate in Oklab (linear-light) because the sRGB midpoint of
## the 18:30 horizon (#D07A48 warm) and a blue sky is muddy brown; scalars
## interpolate linearly. sc_night is authored, NOT derived from sun
## elevation — windows begin lighting at 18:00 while the sky is still warm.

var keys: Array = []  # sorted by "h"
var sun_azimuth_offset_deg: float = -90.0
var ambient_energy_day: float = 1.0
var ambient_energy_night: float = 0.25
var moon_energy: float = 0.0
var moon_color: Color = Color.WHITE
## Deep-night ambient FLOOR (§2.8, night-readability pass). With
## `AMBIENT_SOURCE_SKY` the ambient colour IS the night sky, which is authored
## near-black — so `ambient_energy_night` multiplies ~0.003 of radiance and
## every unlit face resolves to 0 on an AMOLED panel. The floor is a second
## ambient source: an authored blue-grey moonlight colour that the environment
## crossfades IN as `sky_contribution` falls, so the night ground and the unlit
## façades sit on a readable moonlit base instead of on the sky's black.
##
## The crossfade rides `night ^ ambient_floor_gamma`, NOT `night`: at 18:30
## night is already 0.40 and a linear blend would push a sixth of the authored
## blue into a sky that is still orange. Squared, dusk gets 0.16 of it and the
## floor is a DEEP-night effect, which is the hour the players cannot read.
var ambient_color_night: Color = Color(1.0, 1.0, 1.0)
var ambient_sky_contribution_day: float = 1.0
var ambient_sky_contribution_night: float = 1.0
var ambient_floor_gamma: float = 2.0
var fog_profiles: Dictionary = {}
var fog_crossfade_s: float = 4.0
var saturation_day: float = 1.05
var saturation_night: float = 0.92
var errors: PackedStringArray = []


func load_from(render_data: Dictionary) -> bool:
	errors.clear()
	var daynight: Dictionary = render_data.get("daynight", {})
	keys = daynight.get("keys", [])
	if keys.size() < 2:
		errors.append("daynight.keys needs at least 2 entries")
		return false
	sun_azimuth_offset_deg = float(daynight.get("sun_azimuth_offset_deg", -90.0))
	ambient_energy_day = float(daynight.get("ambient_energy_day", 1.0))
	ambient_energy_night = float(daynight.get("ambient_energy_night", 0.25))
	moon_energy = float(daynight.get("moon_energy", 0.0))
	moon_color = Color(String(daynight.get("moon_color", "#ffffff")))
	ambient_color_night = Color(String(daynight.get("ambient_color_night", "#ffffff")))
	ambient_sky_contribution_day = float(
			daynight.get("ambient_sky_contribution_day", 1.0))
	ambient_sky_contribution_night = float(
			daynight.get("ambient_sky_contribution_night", 1.0))
	ambient_floor_gamma = maxf(1.0, float(daynight.get("ambient_floor_gamma", 2.0)))
	var environment: Dictionary = render_data.get("environment", {})
	fog_profiles = environment.get("fog", {})
	fog_crossfade_s = float(environment.get("fog_crossfade_s", 4.0))
	saturation_day = float(environment.get("saturation_day", 1.05))
	saturation_night = float(environment.get("saturation_night", 0.92))
	return true


## Sample the gradient at hour ∈ [0, 24). Returns every §2.8 field resolved.
func sample(hour: float) -> Dictionary:
	hour = fposmod(hour, 24.0)
	var n := keys.size()
	var prev: Dictionary = keys[n - 1]
	var next: Dictionary = keys[0]
	var prev_h := float(prev["h"]) - 24.0
	var next_h := float(next["h"])
	for i in n:
		var candidate: Dictionary = keys[i]
		if float(candidate["h"]) <= hour:
			prev = candidate
			prev_h = float(candidate["h"])
			next = keys[(i + 1) % n]
			next_h = float(next["h"]) + (24.0 if i + 1 >= n else 0.0)
	var t := 0.0
	if next_h > prev_h:
		t = (hour - prev_h) / (next_h - prev_h)
	var night := lerpf(float(prev["night"]), float(next["night"]), t)
	var floor_w := pow(night, ambient_floor_gamma)
	return {
		"sky_top": oklab_lerp(Color(String(prev["sky_top"])), Color(String(next["sky_top"])), t),
		"sky_horizon": oklab_lerp(Color(String(prev["sky_hor"])), Color(String(next["sky_hor"])), t),
		"sun_energy": lerpf(float(prev["sun_e"]), float(next["sun_e"]), t),
		"sun_color": oklab_lerp(Color(String(prev["sun_c"])), Color(String(next["sun_c"])), t),
		"sun_elevation_deg": lerpf(float(prev["sun_elev"]), float(next["sun_elev"]), t),
		"sun_azimuth_deg": hour / 24.0 * 360.0 + sun_azimuth_offset_deg,
		"fog_tint": oklab_lerp(Color(String(prev["fog"])), Color(String(next["fog"])), t),
		"night": night,
		"ambient_energy": lerpf(ambient_energy_day, ambient_energy_night, night),
		"ambient_color": ambient_color_night,
		"ambient_sky_contribution": lerpf(ambient_sky_contribution_day,
				ambient_sky_contribution_night, floor_w),
		"ambient_floor": floor_w,
		"saturation": lerpf(saturation_day, saturation_night, night),
	}


## THE SKY's four colours (Wave 17, §2.8), from one `sample()` — the zenith and
## the horizon are the sampled day/night pair, the HAZE is the sampled fog tint
## (so the band the far city fogs into and the band the sky draws at the horizon
## are the same colour, which is what seats the city edge), and the ground
## hemisphere is the fog tint darkened by `sky.ground_darken`. Pure so a test can
## hold the dawn key to it: at 07:00 the horizon is the authored `#C88A5A` and
## the haze is the authored fog `#5A5A66`, never a blend of the two.
func sky_colors(s: Dictionary, ground_darken: float = 0.45) -> Dictionary:
	var horizon: Color = s["sky_horizon"]
	var haze: Color = s["fog_tint"]
	return {
		"zenith": s["sky_top"],
		"horizon": horizon,
		"haze": haze,
		"ground": haze.darkened(clampf(ground_darken, 0.0, 1.0)),
	}


## Fog profile blend for the current conditions (§2.8): the two clear profiles
## blend by `night`; weather profiles crossfade upstream (weather_mix 0..1
## toward `weather_profile`). The far-cull clamp invariant is applied HERE so
## no caller can violate it: fog_depth_end ≤ far_cull, begin ≤ 0.75 × end.
func fog_state(night: float, far_cull_m: float, weather_profile: String = "",
		weather_mix: float = 0.0) -> Dictionary:
	var day_profile: Dictionary = fog_profiles.get("clear_day", {})
	var night_profile: Dictionary = fog_profiles.get("clear_night", {})
	var blended := _lerp_profile(day_profile, night_profile, night)
	if weather_profile != "" and fog_profiles.has(weather_profile) and weather_mix > 0.0:
		blended = _lerp_profile(blended, fog_profiles[weather_profile], clampf(weather_mix, 0.0, 1.0))
	var end_eff := minf(float(blended["end"]), far_cull_m)
	var begin_eff := minf(float(blended["begin"]), 0.75 * end_eff)
	blended["end"] = end_eff
	blended["begin"] = begin_eff
	return blended


static func _lerp_profile(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		if b.has(key) and (a[key] is float or a[key] is int):
			out[key] = lerpf(float(a[key]), float(b[key]), t)
		else:
			out[key] = a[key]
	return out


# ------------------------------------------------------------------- Oklab

static func oklab_lerp(a: Color, b: Color, t: float) -> Color:
	var la := _to_oklab(a)
	var lb := _to_oklab(b)
	return _from_oklab(la.lerp(lb, t))


static func _to_oklab(c: Color) -> Vector3:
	var r := _srgb_to_linear(c.r)
	var g := _srgb_to_linear(c.g)
	var b := _srgb_to_linear(c.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return Vector3(
			0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


static func _from_oklab(lab: Vector3) -> Color:
	var l := pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3.0)
	var m := pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3.0)
	var s := pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3.0)
	var r := 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
	var g := -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
	var b := -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	return Color(_linear_to_srgb(r), _linear_to_srgb(g), _linear_to_srgb(b))


static func _srgb_to_linear(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _linear_to_srgb(c: float) -> float:
	c = clampf(c, 0.0, 1.0)
	return c * 12.92 if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055
