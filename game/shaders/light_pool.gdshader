// Streetlight ground pool (doc 11 §2.10 #3): a fake downward light disc with
// radial falloff — replaces the dynamic light for 95% of streetlights.
// INSTANCE_CUSTOM.r = lit ramp; sc_wetness widens and brightens it.
//
// `fog_disabled` + the vertex day gate are the same fix lamp.gdshader carries:
// depth fog mixed into an ADDITIVE pass adds fog-grey, which drew a flat
// 12 m square of haze on the road under every pole at noon. See lamp.gdshader
// for the full note.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, fog_disabled;

global uniform float sc_night;
global uniform float sc_wetness;

uniform vec3 pool_color: source_color = vec3(1.0, 0.851, 0.627);
uniform float pool_energy = 0.55;
uniform float night_lo = 0.08;
uniform float night_hi = 0.26;

varying float v_lit;
varying float v_gate;

void vertex() {
	v_lit = INSTANCE_CUSTOM.r;
	v_gate = smoothstep(night_lo, night_hi, sc_night) * v_lit;
	VERTEX.xz *= 1.0 + 0.5 * sc_wetness;
	// Daylight: collapse the disc so no fragment is ever shaded (see lamp).
	VERTEX *= step(0.002, v_gate);
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float falloff = pow(clamp(1.0 - d, 0.0, 1.0), 2.0);
	ALBEDO = pool_color * falloff * pool_energy * v_gate
			* (1.0 + 0.6 * sc_wetness);
}
