// Building window shader (doc 11 §2.6). One of exactly two building shaders
// in the game. INSTANCE_CUSTOM: .r emissive_scale (the fraction of windows
// lit), .g damage, .b packed variant/stage/overlay, .a anim_phase.
// UV2 = (-1,-1) on non-façade surfaces, else [0,1]² across the façade.
// Vertex COLOR carries baked AO (§2.14).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
global uniform float sc_time;

uniform float window_cols = 4.0;
uniform float window_rows = 3.0;
uniform vec3 window_color: source_color = vec3(1.0, 0.808, 0.541);
uniform float window_nits = 3.2;
uniform vec3 base_albedo: source_color = vec3(0.60, 0.585, 0.565);
uniform vec3 soot_color: source_color = vec3(0.278, 0.263, 0.239);
uniform float near_flicker = 1.0;
uniform float day_gate = 0.06;

varying vec4 v_custom;
varying vec2 v_uv2;
varying vec4 v_color;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_uv2 = UV2;
	v_color = COLOR;
}

void fragment() {
	float packed = v_custom.b;
	float variant = mod(packed, 16.0);

	if (v_uv2.x < 0.0) {
		EMISSION = vec3(0.0);
	} else {
		vec2 cell = floor(v_uv2 * vec2(window_cols, window_rows));
		float h = hash21(cell + vec2(variant * 37.0, variant * 11.0));
		float gate = mix(day_gate, 1.0, sc_night);
		float e = v_custom.r * gate;
		float lit = step(1.0 - e, h);          // emissive_scale IS the lit fraction
		float vary = 0.35 + 0.65 * hash21(cell + 91.0);
		float flk = 1.0 - near_flicker * 0.25
				* step(0.985, hash21(cell + floor(sc_time * 3.0)));
		EMISSION = window_color * lit * vary * flk * window_nits
				* (1.0 - 0.6 * v_custom.g);
	}
	ALBEDO = base_albedo * v_color.rgb;                       // baked vertex AO
	// Per-building facade variation: variant shifts tone slightly so a block
	// of identical archetypes never reads as copy-paste.
	float tint = (variant / 15.0 - 0.5) * 0.16;
	ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
	ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);   // damage soot
	ROUGHNESS = 0.85;
	SPECULAR = 0.35;
}
