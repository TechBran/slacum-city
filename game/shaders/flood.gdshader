// Standing water on a flooded street — doc 07 §2.4 drawn at last (A91-D-26).
//
// What this replaces is NOTHING, and that is the point. `sim/weather/
// flood_field.gd` has been integrating `depth_mm` on the utilities cadence
// since the weather system shipped; a two-real-hour soak logs 460
// `flood_level_changed`, doc 10 closes edges off it, and until this file the
// player's only evidence that any of it happened was a road that had quietly
// stopped working. Doc 07 §2.4's own note says it out loud: *standing water is
// integrated continuously and is never drawn, never announced and never
// logged.*
//
// ── the read, in one sentence ─────────────────────────────────────────────
// Water arrives as PUDDLES in the gutters, joins up into a sheet, climbs the
// kerb, and when it drains it leaves the asphalt dark for a minute. Every one
// of those four is a different value of two floats, and the two floats are
// per-instance:
//
//   INSTANCE_CUSTOM.r  `water01`  eased depth / 350 mm (doc 07's own
//                                 `flood_saturation` divisor — the impassable
//                                 band). 0 dry, 1 the street is gone.
//   INSTANCE_CUSTOM.g  `wet01`    the dark-wet memory. Rises with the water,
//                                 falls on a much longer tau, so a receded
//                                 street stays black and glossy for a while
//                                 after the last of the water has gone.
//   INSTANCE_CUSTOM.b  reserved (0).
//   INSTANCE_CUSTOM.a  reserved (0).
//
// Two channels, and the other two are empty ON PURPOSE — see the note on the
// lattice in `fragment()`. Anything per-tile in this surface draws the tile
// grid.
//
// **Coverage is where the rise reads, not height.** A 350 mm flood is 35 cm of
// water on an 8 m tile: at the camera's 34°–62° pitch band the geometric rise
// is a few pixels and nobody would ever see it. So the depth drives *how much
// of the tile is wet* through a world-space noise threshold — low water wets
// only the low ground, high water wets everything — and the sheet ALSO lifts by
// `rise_m` so that at the impassable band it stands above the 0.25 m kerb the
// footway sits on. The lift is the confirmation; the coverage is the read.
//
// **World-space, like `water.gdshader`.** The noise is driven off world XZ, so
// two adjacent 8 m tiles are one puddle rather than two tiles that happen to be
// wet, and a flood that spans a land block reads as one body of water. Driving
// it off UV would restart the pattern at every tile and paint a grid.
//
// **No texture fetch anywhere**, so there is no divergent-flow question to
// answer: the whole surface is arithmetic, and the `detail` ladder below is the
// only branch, uniform across the draw.
//
// ── the fragment ladder (§2.13: the Fold frame is FRAGMENT-BOUND) ─────────
//   2  full: ripple normal (one octave + two finite differences) and the
//      noise-threshold coverage — four `vnoise` calls.
//   1  coverage only, flat normal — one `vnoise`. The sheet still grows and
//      still mirrors; it just does not crawl.
//   0  no noise at all: a flat sheet that fades in with the depth. One
//      smoothstep. This is what Performance ships, and on a 0.7 render scale a
//      puddle's ripple was never resolvable anyway.
//
// ── night ────────────────────────────────────────────────────────────────
// Report NIGHT-1's lesson, applied to a surface that did not exist when it was
// written: a body of water at night is a MIRROR OF THE SKY, and the fresnel
// term therefore retargets from the authored daytime `sky_color` onto
// `sc_fog_tint`, exactly as `water.gdshader` does. A flooded street at 23:00 is
// where the lamps smear, which is the single best-looking thing this feature
// buys — and getting it wrong would have cut a black rectangle through a lit
// street, which reads as missing geometry, not as water.
shader_type spatial;
render_mode cull_back, depth_draw_never, blend_mix, shadows_disabled;

global uniform float sc_time;
global uniform float sc_night;
global uniform float sc_wetness;
global uniform vec2 sc_wind;
global uniform int sc_overlay_mode;
global uniform vec3 sc_fog_tint;

uniform vec3 deep_color: source_color = vec3(0.086, 0.196, 0.243);
uniform vec3 shallow_color: source_color = vec3(0.200, 0.314, 0.353);
uniform vec3 wet_color: source_color = vec3(0.169, 0.173, 0.188);
uniform vec3 sky_color: source_color = vec3(0.431, 0.576, 0.706);
uniform vec3 night_glow_color: source_color = vec3(0.424, 0.533, 0.769);

// Geometry. `rise_m` is added in the vertex stage on top of whatever y the
// instance transform put the quad at; the caller parks it just above the
// asphalt so a dry tile's sheet is coplanar-but-above and never z-fights.
uniform float rise_m = 0.20;

uniform float water_alpha = 0.92;
uniform float wet_alpha = 0.55;
uniform float puddle_scale_m = 5.5;
uniform float puddle_contrast = 0.90;
uniform float edge_softness = 0.12;
// Coverage is deliberately NOT linear in depth. Doc 07's bands are 0-39 /
// 40-99 / 100-199 / 200-349 / 350+, so `standing water` — the band where
// vehicles start stalling — is only 0.29 of the way to the divisor, and a
// linear ramp put a third of a tile under water at the depth the sim was
// already stalling traffic on. `pow(water01, coverage_gamma)` with gamma 0.45
// puts the four bands at roughly 20 / 50 / 90 / 100 % of the tile, which is
// what the bands MEAN. Measured against the shots in report 98.
uniform float coverage_gamma = 0.45;

uniform float ripple_scale_m = 2.2;
uniform float ripple_speed = 0.09;
uniform float ripple_amp = 0.10;
uniform float wind_gain = 0.05;

uniform float sparkle_gain = 0.22;
uniform float sparkle_power = 8.0;
uniform float base_roughness = 0.10;
uniform float base_specular = 0.85;
uniform float rain_chop_gain = 0.85;

// ── the night floor, report NIGHT-1 applied to a surface it predates ──────
// Measured before these existed: at 22:00 a 490 mm flood over an unlit stretch
// of asphalt was INVISIBLE. `night_mult 0.55` on an already-dark body put the
// water below the road it was standing on, and a flooded street that is darker
// than the dry street beside it is not a picture of anything.
//
// The physical read is the opposite way round, and it is the one everybody has
// seen from a car: a wet road at night is LIGHTER than a dry one, because it
// has stopped diffusing and started mirroring — the sky, the lamps, the
// headlights. So three terms, all riding `sc_night` and all zero by day:
// `night_mult` barely darkens, `night_lift` adds a cool bounce off the sampled
// fog tint, and `night_glow` is the skyglow floor that survives ambient going
// to zero. Same three ideas as `ground.gdshader`, aimed the other way.
uniform float night_mult = 0.80;
uniform float night_lift = 0.12;
uniform float night_sky_blend = 0.75;
uniform float night_sky_gain = 3.2;
uniform float night_glow = 0.055;

uniform float fresnel_power = 3.6;
uniform float fresnel_gain = 0.44;

uniform float overlay_desaturate = 0.55;

uniform int detail = 2;

// `v_pack` is INSTANCE_CUSTOM and is CONSTANT over an instance: `flat`, exactly
// as doc 11 §2.6 requires of every custom-data varying. Interpolating a depth
// across a quad would bleed one tile's water level into its neighbour's.
varying flat vec4 v_pack;
varying vec3 v_world;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// The same value noise `water.gdshader` and `building.gdshader` use. Sharing it
// is deliberate: a puddle and the canal it is draining toward must not read as
// two different materials that happen to both be blue.
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
	v_pack = INSTANCE_CUSTOM;
	VERTEX.y += v_pack.r * rise_m;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float water01 = clamp(v_pack.r, 0.0, 1.0);
	float wet01 = clamp(v_pack.g, 0.0, 1.0);

	// How much of THIS fragment is under water. `pool` is the depth, pulled
	// down wherever the ground noise says the tile is high; the smoothstep is
	// the shoreline and `edge_softness` is how wide it is. At `detail 0` the
	// noise is dropped and the sheet simply fades in, which is a coarser
	// picture of the same fact.
	//
	// **There is no per-tile term anywhere in this expression, and there were
	// two.** The first biased the pool toward the quad's own UV edge to stand
	// in for a gutter; the second phased the noise by a hash of the tile so
	// that "which corner holds the last puddle" would be a fact about the city.
	// Both are reasonable ideas and both drew the same thing on screen: a wet
	// 8 m LATTICE over the city — the tile grid, in water. Any function of the
	// instance breaks the one thing this surface has to do, which is read as
	// ONE body across a whole flooded block. So coverage is a function of world
	// position and cell depth and of nothing else — which also makes the
	// picture a pure function of the sim, with no seed to persist.
	float depth_curve = pow(water01, coverage_gamma);
	float coverage = clamp(depth_curve, 0.0, 1.0);
	if (detail > 0) {
		float ground = vnoise(v_world.xz / max(puddle_scale_m, 0.01));
		float pool = depth_curve * (1.0 + puddle_contrast)
				- ground * puddle_contrast;
		coverage = smoothstep(0.5 - edge_softness, 0.5 + edge_softness, pool);
	}

	// The ripple. One octave plus two finite differences is enough to make the
	// specular highlight crawl, and a puddle does not need the canal's second
	// octave — the body is 8 m across, not 15 tiles.
	vec3 n = vec3(0.0, 1.0, 0.0);
	float swell = 0.5;
	if (detail > 1) {
		vec2 flow = normalize(vec2(1.0, 0.35) + sc_wind * wind_gain);
		vec2 uv = v_world.xz / max(ripple_scale_m, 0.01)
				+ flow * sc_time * ripple_speed;
		float na = vnoise(uv);
		swell = na;
		float e = 0.35;
		float dx = vnoise(uv + vec2(e, 0.0)) - na;
		float dz = vnoise(uv + vec2(0.0, e)) - na;
		float chop = mix(1.0, 1.0 + rain_chop_gain, sc_wetness);
		n = normalize(vec3(-dx * ripple_amp * 12.0 * chop, 1.0,
				-dz * ripple_amp * 12.0 * chop));
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// Deeper water is darker: the band the player is in reads as a colour as
	// well as an extent, so a glance at the street says "ankle" or "axle".
	vec3 body = mix(shallow_color, deep_color, water01);
	// Grazing angles become sky — at night, the SAMPLED sky (report NIGHT-1).
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	vec3 sky = mix(sky_color, sc_fog_tint * night_sky_gain, sc_night * night_sky_blend);
	body = mix(body, sky, clamp(f * fresnel_gain, 0.0, 1.0));
	body *= mix(1.0, night_mult, sc_night);
	// The lift: a cool bounce off the sampled night sky, so the water sits
	// ABOVE the asphalt in luminance instead of under it.
	body += sc_fog_tint * night_sky_gain * (night_lift * sc_night);

	// Under and around the water: asphalt that has been soaked. This is the
	// halo, and it is what the tile keeps after the water has gone.
	vec3 damp = wet_color * mix(1.0, night_mult, sc_night * 0.6);

	ALBEDO = mix(damp, body, coverage);
	ALPHA = clamp(max(wet01 * wet_alpha, coverage * water_alpha * wet01), 0.0, 1.0);

	// Sun glints on the crests, killed by rain and by night along with the
	// roughness — the same trade `water.gdshader` makes for the same reason.
	float crest = pow(clamp(swell, 0.0, 1.0), sparkle_power) * coverage;
	float glint = crest * sparkle_gain * (1.0 - sc_night) * (1.0 - 0.85 * sc_wetness);
	EMISSION = sky_color * glint
			+ night_glow_color * (night_glow * sc_night * coverage);

	ROUGHNESS = mix(0.62, base_roughness, coverage) + 0.35 * sc_wetness * coverage;
	SPECULAR = mix(0.45, base_specular, coverage) * (1.0 - 0.25 * sc_wetness);
	METALLIC = 0.0;

	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		EMISSION *= 0.40;
	}
}
