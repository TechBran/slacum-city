// Streetlight ground pool (doc 11 §2.10 #3): a fake downward light disc with
// radial falloff — replaces the dynamic light for 95% of streetlights.
// INSTANCE_CUSTOM.r = lit ramp; sc_wetness widens and brightens it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;

global uniform float sc_night;
global uniform float sc_wetness;

uniform vec3 pool_color: source_color = vec3(1.0, 0.851, 0.627);
uniform float pool_energy = 0.55;

varying float v_lit;

void vertex() {
	v_lit = INSTANCE_CUSTOM.r;
	VERTEX.xz *= 1.0 + 0.5 * sc_wetness;
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float falloff = pow(clamp(1.0 - d, 0.0, 1.0), 2.0);
	ALBEDO = pool_color * falloff * pool_energy * v_lit * sc_night
			* (1.0 + 0.6 * sc_wetness);
}
