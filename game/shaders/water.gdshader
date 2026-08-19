// Water surface (doc 11 §2.1's third ground surface).
//
// What this replaces: a StandardMaterial3D with `albedo = #1A3350`,
// `roughness 0.15`, `metallic 0.2`. Flat, saturated, and — because it is one
// constant colour over a 15-tile canal — the only surface in the game that
// reads as untextured placeholder art at any zoom, in any weather, at any hour.
//
// What it is instead: two scrolling value-noise octaves at different scales,
// speeds and headings (so the pattern never repeats visibly and never looks
// like one sheet sliding), a fresnel-weighted lift toward the sky colour at
// grazing angles, and a night multiplier. Nothing here is per-frame CPU work:
// the animation rides `sc_time`, which the window flicker already publishes.
//
// **No reflection probe, deliberately.** §2.11 allows the game exactly one
// probe, gated to High and already flagged for on-device validation. Water
// that needs a second one is water that cannot ship on the mobile presets, so
// the sky read is faked with a fresnel term: `mix(body, sky_color, fresnel)`.
// At the camera's 34°–62° pitch band that is within a few percent of what a
// probe would return for a flat horizontal surface under a gradient sky, and
// it costs one dot product.
//
// Rain and the day/night curve both reach it: `sc_wetness` roughens the
// surface into chop (a downpour kills specular glare — the real-world read
// everyone knows and nobody can name), `sc_night` darkens the body, and
// `sc_overlay_mode` greys it back with every other surface so an overlay does
// not leave one glowing blue rectangle in the middle of a desaturated city.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_time;
global uniform float sc_night;
global uniform float sc_wetness;
global uniform int sc_overlay_mode;

uniform vec3 deep_color: source_color = vec3(0.071, 0.188, 0.247);
uniform vec3 shallow_color: source_color = vec3(0.118, 0.306, 0.361);
uniform vec3 sky_color: source_color = vec3(0.431, 0.576, 0.706);
uniform float night_mult = 0.34;
uniform float fresnel_power = 3.4;
uniform float fresnel_gain = 0.55;

// Two octaves. A is the swell — long, slow, nearly cross-current; B is the
// ripple — short, quicker, running the other way. Two headings is what stops
// the eye locking onto a single scroll direction.
uniform float wave_scale_a_m = 7.5;
uniform float wave_scale_b_m = 2.6;
uniform float wave_speed_a = 0.035;
uniform float wave_speed_b = 0.11;
uniform vec2 wave_dir_a = vec2(1.0, 0.32);
uniform vec2 wave_dir_b = vec2(-0.55, 1.0);
uniform float wave_amp = 0.16;

uniform float sparkle_gain = 0.45;
uniform float sparkle_power = 7.0;
uniform float base_roughness = 0.08;
uniform float base_specular = 0.85;
// A downpour turns a mirror into chop: roughness up, sparkle down.
uniform float rain_chop_gain = 0.85;

// Optional detail page from tools/gen_textures.py (`ground_water.png`). Absent
// on a clone that has not run the generator, and the shader is complete
// without it — has_page = 0 is the authored look, not a degraded one.
uniform sampler2D page: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float has_page = 0.0;
uniform float page_tile_m = 4.0;
uniform float page_blend = 0.18;

varying vec3 v_world;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// Value noise: the same hash the building shader uses, bilinearly smoothed.
// Cheap, and at these scales indistinguishable from anything more expensive.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World-space, so neighbouring tiles are ONE body of water: the wave
	// pattern crosses tile seams without a break. Driving this off UV would
	// restart the noise at every 8 m quad and the canal would read as tiling.
	vec2 w = v_world.xz;
	vec2 a_uv = w / max(wave_scale_a_m, 0.01)
			+ normalize(wave_dir_a) * sc_time * wave_speed_a;
	vec2 b_uv = w / max(wave_scale_b_m, 0.01)
			+ normalize(wave_dir_b) * sc_time * wave_speed_b;
	float na = vnoise(a_uv);
	float nb = vnoise(b_uv);
	float swell = na * 0.65 + nb * 0.35;

	// Gradients of the two octaves, by finite difference, become a normal
	// perturbation — enough to make the specular highlight crawl, far short of
	// what a real normal map would cost.
	float e = 0.35;
	float dx = (vnoise(a_uv + vec2(e, 0.0)) - na) * 0.65
			+ (vnoise(b_uv + vec2(e, 0.0)) - nb) * 0.35;
	float dz = (vnoise(a_uv + vec2(0.0, e)) - na) * 0.65
			+ (vnoise(b_uv + vec2(0.0, e)) - nb) * 0.35;
	float chop = mix(1.0, 1.0 + rain_chop_gain, sc_wetness);
	vec3 n = normalize(vec3(-dx * wave_amp * 12.0 * chop, 1.0,
			-dz * wave_amp * 12.0 * chop));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	vec3 body = mix(deep_color, shallow_color, swell);
	if (has_page > 0.5) {
		vec3 detail = texture(page, w / max(page_tile_m, 0.01)).rgb;
		body = mix(body, body * (0.5 + detail), page_blend);
	}

	// Fresnel off the perturbed normal: looking down, the water is its own
	// colour; at a grazing angle it becomes the sky. `VIEW` is the fragment →
	// camera vector in view space, which is exactly what this needs.
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	ALBEDO = mix(body, sky_color, clamp(f * fresnel_gain, 0.0, 1.0));
	// Night: the body darkens, the sky term darkens with it. Water at midnight
	// under a #080C18 sky is not blue, it is almost black with a rim.
	ALBEDO *= mix(1.0, night_mult, sc_night);

	// Sun glints on the crests. Squeezed hard so it is a scatter of points, not
	// a sheen, and pulled down by rain along with the roughness.
	float crest = pow(clamp(swell, 0.0, 1.0), sparkle_power);
	float glint = crest * sparkle_gain * (1.0 - sc_night) * (1.0 - 0.85 * sc_wetness);
	EMISSION = sky_color * glint;

	ROUGHNESS = clamp(base_roughness + 0.55 * sc_wetness, 0.0, 1.0);
	SPECULAR = base_specular * (1.0 - 0.35 * sc_wetness);
	METALLIC = 0.0;

	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), 0.55);
		EMISSION *= 0.40;
	}
}
